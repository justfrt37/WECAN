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

    enum EndReason: Equatable { case userEnded, insufficientTokens, error }
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
            state = .ended(reason: .insufficientTokens)
            return
        } catch {
            debug("voice-call-start failed: \(error)")
            errorMessage = String(localized: "Couldn't start the call.")
            state = .ended(reason: .error)
            return
        }
        callSessionId = result.callSessionId

        let config = ConversationConfig(
            agentOverrides: AgentOverrides(
                prompt: result.systemPrompt, firstMessage: result.firstMessage, language: Language(rawValue: languageCode)
            ),
            ttsOverrides: TTSOverrides(voiceId: result.voiceId, stability: result.stability),
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
        } catch {
            debug("ElevenLabs connect failed: \(error)")
            errorMessage = String(localized: "Couldn't connect the call.")
            state = .ended(reason: .error)
            return
        }

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
        if reason == .error {
            errorMessage = String(localized: "The call was disconnected.")
            state = .ended(reason: .error)
        } else {
            state = .ended(reason: .userEnded)
        }
    }

    func endCall() async {
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
        if !isEnded { state = .ended(reason: .userEnded) }
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
