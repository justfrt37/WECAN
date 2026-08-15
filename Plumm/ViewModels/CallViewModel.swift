//
//  CallViewModel.swift
//  Real-time voice call durumu, backed by an ElevenLabs Agents session
//  (Flash v2.5). The SDK (built on LiveKit WebRTC) owns mic capture, ASR,
//  TTS playback, and barge-in natively — this class just wires our token
//  billing and DEBUG logging around it. See
//  docs/superpowers/specs/2026-07-29-voice-call-agents-migration-design.md.
//

import Foundation
import ElevenLabs
import Observation

enum CallState: Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case ended(reason: EndReason)

    /// `notEntitled`: ses Pro+ / Pro Max hakkı (bkz. _shared/entitlements.ts) —
    /// aramayı kapatıp yükseltme paywall'ı gösterilir.
    enum EndReason: Equatable { case userEnded, insufficientTokens, notEntitled, error }
}

@MainActor
@Observable
final class CallViewModel {
    let character: Character
    let conversationId: String?
    var tokenStore: TokenStore?

    var state: CallState = .idle
    var isMuted: Bool = false
    var errorMessage: String?
    /// Tokens charged for this call, set right before `state` becomes
    /// `.ended` — VoiceCallView shows a brief "-N" animation from this
    /// (unlike TokenBadge's app-wide silent-spend convention, a call's
    /// cost is variable/unpredictable so it's worth confirming on-screen).
    var tokensCharged: Int?

    // TEMP DEBUG — remove once voice call pipeline is verified on device.
    var debugLog: [String] = []
    private func debug(_ s: String) { debugLog.append(s) }

    private let service = CallService()
    private let soundPlayer = CallSoundPlayer()
    private var conversation: Conversation?

    private var callSessionId: String?
    private var callStartedAt: Date?
    private var checkpointTask: Task<Void, Never>?

    init(character: Character, conversationId: String?) {
        self.character = character
        self.conversationId = conversationId
    }

    var elapsedSeconds: Double {
        guard let callStartedAt else { return 0 }
        return Date().timeIntervalSince(callStartedAt)
    }

    private var isEnded: Bool {
        if case .ended = state { return true }
        return false
    }

    func startCall() async {
        // Chat's own detected language for this character (falls back to
        // device locale if there's no chat history yet) — same 7-language
        // set + ISO codes as ElevenLabs' `Language` enum, so no translation
        // table needed between the two.
        let languageCode = ConversationLanguage.current(for: character.id)
        debug("Calling voice-call-start… (language: \(languageCode))")
        soundPlayer.startRinging()
        let result: CallService.StartResult
        do {
            result = try await service.start(
                characterId: character.id.uuidString.lowercased(),
                conversationId: conversationId,
                reviewMode: ReviewModeService.isEnabledSnapshot,
                language: languageCode
            )
            debug("Call started, session \(result.callSessionId)")
        } catch CallServiceError.insufficientTokens {
            debug("voice-call-start: insufficient tokens")
            soundPlayer.stopRinging()
            state = .ended(reason: .insufficientTokens)
            return
        } catch CallServiceError.notEntitled {
            soundPlayer.stopRinging()
            state = .ended(reason: .notEntitled)
            return
        } catch {
            debug("voice-call-start failed: \(error)")
            errorMessage = String(localized: "Couldn't start the call.")
            soundPlayer.stopRinging()
            state = .ended(reason: .error)
            return
        }
        callSessionId = result.callSessionId

        let config = ConversationConfig(
            agentOverrides: AgentOverrides(
                prompt: result.systemPrompt, firstMessage: result.firstMessage, language: Language(rawValue: languageCode)
            ),
            ttsOverrides: TTSOverrides(voiceId: result.voiceId, stability: result.stability, speed: result.speed),
            customLlmExtraBody: ["callSessionId": result.callSessionId],
            onDisconnect: { [weak self] reason in
                Task { @MainActor in self?.handleDisconnect(reason) }
            },
            onError: { [weak self] error in
                Task { @MainActor in self?.debug("SDK error: \(error)") }
            },
            onAgentResponse: { [weak self] text, _ in
                Task { @MainActor in self?.debug("Agent said: \"\(text)\"") }
            },
            onUserTranscript: { [weak self] text, _ in
                Task { @MainActor in self?.debug("User said: \"\(text)\"") }
            },
            onAgentStateChange: { [weak self] agentState in
                Task { @MainActor in self?.applyAgentState(agentState) }
            }
        )

        do {
            debug("Connecting to ElevenLabs Agent…")
            conversation = try await ElevenLabs.startConversation(
                conversationToken: result.conversationToken, config: config
            )
            debug("Agent connected")
        } catch ConversationError.microphoneToggleFailed(let reason) {
            // Mic unavailable (permission denied, hardware issue, or — on
            // Simulator — the known-flaky audio HAL) shouldn't kill the call;
            // fall back to text-only so the app's typed-message path still works.
            debug("Mic unavailable (\(reason)) — retrying text-only")
            errorMessage = String(localized: "Microphone unavailable — continuing with text only.")
            var textOnlyConfig = config
            textOnlyConfig.conversationOverrides = ConversationOverrides(textOnly: true)
            do {
                conversation = try await ElevenLabs.startConversation(
                    conversationToken: result.conversationToken, config: textOnlyConfig
                )
                debug("Agent connected (text-only)")
            } catch {
                debug("Text-only retry failed: \(error)")
                errorMessage = String(localized: "Couldn't connect the call.")
                soundPlayer.stopRinging()
                state = .ended(reason: .error)
                return
            }
        } catch {
            debug("ElevenLabs connect failed: \(error)")
            errorMessage = String(localized: "Couldn't connect the call.")
            soundPlayer.stopRinging()
            state = .ended(reason: .error)
            return
        }

        soundPlayer.stopRinging()
        callStartedAt = Date()
        state = .listening
        startCheckpointLoop()
    }

    private func applyAgentState(_ agentState: ElevenLabs.AgentState) {
        guard !isEnded else { return }
        switch agentState {
        case .listening: state = .listening
        case .thinking: state = .thinking
        case .speaking: state = .speaking
        }
    }

    private func handleDisconnect(_ reason: DisconnectionReason) {
        guard !isEnded else { return }
        debug("Disconnected: \(reason)")
        // Only a call that actually connected (reached .listening at least
        // once) gets the "hung up" chime — a pre-connection failure already
        // just stops the ringback, no false "call ended" cue.
        if callStartedAt != nil { soundPlayer.playEndTone() }
        if reason == .error {
            errorMessage = String(localized: "The call was disconnected.")
            state = .ended(reason: .error)
        } else {
            state = .ended(reason: .userEnded)
        }
    }

    func endCall() async {
        soundPlayer.stopRinging() // no-op if already stopped — covers hangup mid-ring
        checkpointTask?.cancel()
        await conversation?.endConversation()
        conversation = nil

        let finalElapsed = elapsedSeconds
        debug("Ending call, elapsedSeconds=\(finalElapsed)")
        if let callSessionId {
            do {
                let result = try await service.end(callSessionId: callSessionId, actualElapsedSeconds: finalElapsed)
                debug("voice-call-end: charged \(result.tokensCharged) tokens, newBalance=\(result.newBalance)")
                tokensCharged = result.tokensCharged
                tokenStore?.setBalance(result.newBalance)
            } catch {
                debug("voice-call-end FAILED: \(error)")
            }
        } else {
            debug("Ending call: no callSessionId — never started, nothing to charge")
        }
        // Guarded the same way the state assignment below is — if
        // `conversation?.endConversation()` already triggered
        // handleDisconnect (which plays its own end tone) before we get
        // here, isEnded is already true and this doesn't double-play.
        if !isEnded {
            if callStartedAt != nil { soundPlayer.playEndTone() }
            state = .ended(reason: .userEnded)
        }
    }

    func toggleMute() {
        isMuted.toggle()
        Task { try? await conversation?.setMuted(isMuted) }
    }

    /// Text fallback for a turn — same pipeline as a spoken turn (the Agent
    /// treats it identically to a transcribed utterance).
    func sendTypedText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let conversation else { return }
        debug("Typed: \"\(trimmed)\"")
        do {
            try await conversation.sendMessage(trimmed)
        } catch {
            debug("sendMessage failed: \(error)")
            errorMessage = String(localized: "That message failed — try again.")
        }
    }

    // MARK: - Checkpointing

    private func startCheckpointLoop() {
        checkpointTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let callSessionId else { continue }
                let ok = (try? await service.checkpoint(callSessionId: callSessionId, elapsedSeconds: elapsedSeconds)) ?? true
                if !ok {
                    state = .ended(reason: .insufficientTokens)
                    await endCall()
                    return
                }
            }
        }
    }
}
