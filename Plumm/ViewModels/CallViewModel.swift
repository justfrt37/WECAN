//
//  CallViewModel.swift
//  Real-time voice call durumu: listening -> thinking -> speaking, barge-in destekli.
//

import Foundation
import AVFoundation
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
final class CallViewModel: NSObject, AVAudioPlayerDelegate {
    let character: Character
    let conversationId: String?
    var tokenStore: TokenStore?

    var state: CallState = .idle
    var isMuted: Bool = false
    var errorMessage: String?

    private let service = CallService()
    private let recognizer = SpeechRecognizer()
    private var player: AVAudioPlayer?

    private var callSessionId: String?
    private var callStartedAt: Date?
    private var checkpointTask: Task<Void, Never>?
    private var turnLoopTask: Task<Void, Never>?
    private var bargeInWatchTask: Task<Void, Never>?

    init(character: Character, conversationId: String?) {
        self.character = character
        self.conversationId = conversationId
    }

    private var elapsedSeconds: Double {
        guard let callStartedAt else { return 0 }
        return Date().timeIntervalSince(callStartedAt)
    }

    func startCall() async {
        await recognizer.requestAuthorization()
        guard recognizer.authorized else {
            errorMessage = String(localized: "Microphone/Speech access is required for calls.")
            state = .ended(reason: .error)
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers, .allowBluetooth, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = String(localized: "Couldn't start the call's audio session.")
            state = .ended(reason: .error)
            return
        }

        do {
            callSessionId = try await service.start(characterId: character.id.uuidString.lowercased(), conversationId: conversationId)
        } catch CallServiceError.insufficientTokens {
            state = .ended(reason: .insufficientTokens)
            return
        } catch {
            errorMessage = String(localized: "Couldn't start the call.")
            state = .ended(reason: .error)
            return
        }

        callStartedAt = Date()
        startCheckpointLoop()
        turnLoopTask = Task { await runListenTurn() }
    }

    func endCall() async {
        checkpointTask?.cancel()
        turnLoopTask?.cancel()
        bargeInWatchTask?.cancel()
        recognizer.cancel()
        player?.stop()
        player = nil

        let finalElapsed = elapsedSeconds
        if let callSessionId {
            if let result = try? await service.end(callSessionId: callSessionId, actualElapsedSeconds: finalElapsed) {
                tokenStore?.setBalance(result.newBalance)
            }
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if case .ended = state {} else { state = .ended(reason: .userEnded) }
    }

    func toggleMute() {
        isMuted.toggle()
        if isMuted { recognizer.cancel() }
    }

    // MARK: - Turn loop

    private func runListenTurn() async {
        guard !isMuted else {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !Task.isCancelled { turnLoopTask = Task { await self.runListenTurn() } }
            return
        }
        state = .listening
        recognizer.start(configuresSession: false)

        while recognizer.isRecording, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        guard !Task.isCancelled else { return }

        let transcript = recognizer.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty, let callSessionId else {
            turnLoopTask = Task { await self.runListenTurn() }
            return
        }

        state = .thinking
        do {
            let result = try await service.sendTurn(
                callSessionId: callSessionId, transcript: transcript, reviewMode: ReviewModeService.isEnabledSnapshot
            )
            guard !Task.isCancelled else { return }
            await speak(result.audioData)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = String(localized: "That turn failed — try speaking again.")
            turnLoopTask = Task { await self.runListenTurn() }
        }
    }

    private func speak(_ audioData: Data) async {
        state = .speaking
        do {
            let p = try AVAudioPlayer(data: audioData)
            p.delegate = self
            player = p
            p.play()
        } catch {
            turnLoopTask = Task { await self.runListenTurn() }
            return
        }

        // Barge-in watcher: reuse the SAME recognizer instance concurrently
        // with playback (duplex session from startCall handles echo
        // cancellation) — any non-trivial partial transcript while `speaking`
        // means the user started talking over the AI.
        recognizer.start(configuresSession: false)
        bargeInWatchTask = Task {
            while state == .speaking, !Task.isCancelled {
                if recognizer.transcript.trimmingCharacters(in: .whitespacesAndNewlines).count > 2 {
                    player?.stop()
                    player = nil
                    state = .listening
                    // Recognizer keeps running — its current session becomes
                    // this next turn's capture, picked up by the poll loop below.
                    while recognizer.isRecording, !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                    }
                    guard !Task.isCancelled else { return }
                    let transcript = recognizer.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !transcript.isEmpty, let callSessionId else {
                        turnLoopTask = Task { await self.runListenTurn() }
                        return
                    }
                    state = .thinking
                    do {
                        let result = try await service.sendTurn(
                            callSessionId: callSessionId, transcript: transcript, reviewMode: ReviewModeService.isEnabledSnapshot
                        )
                        await speak(result.audioData)
                    } catch {
                        errorMessage = String(localized: "That turn failed — try speaking again.")
                        turnLoopTask = Task { await self.runListenTurn() }
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.state == .speaking else { return }
            self.bargeInWatchTask?.cancel()
            self.recognizer.cancel() // discard the barge-in listener session, start fresh next turn
            self.player = nil
            self.turnLoopTask = Task { await self.runListenTurn() }
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
