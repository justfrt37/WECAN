//
//  CallSoundPlayer.swift
//  Ringback tone while a voice call connects + a short tone when it ends.
//  No bundled audio assets exist in the project — both tones are
//  synthesized in-memory as WAV data (sine tones + short fades to avoid
//  clicks), same AVAudioPlayer + `.playback`/`.duckOthers` session
//  convention VoicePlayer.swift already uses for TTS playback.
//

import AVFoundation

@MainActor
final class CallSoundPlayer: NSObject {
    private var player: AVAudioPlayer?

    func startRinging() {
        stopPlayback()
        activateSession()
        let p = try? AVAudioPlayer(data: Self.ringtoneData)
        p?.numberOfLoops = -1
        p?.volume = 0.5
        p?.play()
        player = p
    }

    /// - Parameter deactivate: pass `false` when the ringback is stopping
    ///   because the call just went LIVE. Deactivating here tore down the very
    ///   session the ElevenLabs SDK had just taken over, so the call connected
    ///   and then lost its audio immediately. Every other caller — the error
    ///   paths and hangup — really is finished with audio and keeps the default.
    func stopRinging(deactivate: Bool = true) {
        stopPlayback()
        if deactivate { deactivateSession() }
    }

    /// Fire-and-forget — deactivates the audio session itself once playback
    /// finishes (delegate callback), no need for the caller to clean up.
    func playEndTone() {
        stopPlayback()
        activateSession()
        let p = try? AVAudioPlayer(data: Self.endToneData)
        p?.volume = 0.6
        p?.delegate = self
        p?.play()
        player = p
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
    }

    /// `.playAndRecord`, not `.playback` — and that is the whole reason calls
    /// had no audio in either direction.
    ///
    /// The ringback starts first (CallViewModel.startCall → startRinging) and
    /// activates the session, and it was activating it as `.playback`, which is
    /// an OUTPUT-ONLY category. The ElevenLabs SDK then tried to open the mic on
    /// top of that session and AVAudioEngine refused with error -3001. The SDK
    /// fell back to a text-only conversation, which fails as well because
    /// text-only needs a public agent id or a signed WebSocket URL while we
    /// hand it a WebRTC conversation token. Net effect on the device: no mic
    /// captured, no agent audio played, only the debug log showing replies.
    ///
    /// The session is still live when the SDK starts, so the category it finds
    /// has to be one that can record. `.voiceChat` mode is what the SDK expects
    /// for a call; `.defaultToSpeaker` keeps it off the earpiece, since
    /// `.voiceChat` routes there by default and users hold the phone away from
    /// their ear on this screen.
    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth, .duckOthers],
        )
        try? session.setActive(true)
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Tone synthesis

    /// Classic ringback pattern (dual 440/480Hz tone) — 1.2s on, 2.4s off,
    /// looped via `numberOfLoops = -1`.
    private static let ringtoneData: Data = synthesizeWAV(segments: [
        (frequencies: [440, 480], duration: 1.2),
        (frequencies: [], duration: 2.4),
    ])

    /// Two short descending beeps — reads as "call disconnected".
    private static let endToneData: Data = synthesizeWAV(segments: [
        (frequencies: [600], duration: 0.14),
        (frequencies: [], duration: 0.06),
        (frequencies: [400], duration: 0.22),
    ])

    private static func synthesizeWAV(segments: [(frequencies: [Double], duration: Double)], sampleRate: Double = 44100) -> Data {
        var samples: [Int16] = []
        let fadeSamples = Int(0.008 * sampleRate) // 8ms fade in/out, avoids clicks between segments

        for segment in segments {
            let count = Int(segment.duration * sampleRate)
            guard count > 0 else { continue }
            if segment.frequencies.isEmpty {
                samples.append(contentsOf: repeatElement(0, count: count))
                continue
            }
            for i in 0..<count {
                let t = Double(i) / sampleRate
                var value = segment.frequencies.reduce(0.0) { $0 + sin(2 * .pi * $1 * t) }
                value /= Double(segment.frequencies.count)
                let fadeIn = min(1.0, Double(i) / Double(max(fadeSamples, 1)))
                let fadeOut = min(1.0, Double(count - i) / Double(max(fadeSamples, 1)))
                value *= min(fadeIn, fadeOut)
                samples.append(Int16(value * Double(Int16.max) * 0.8))
            }
        }

        return wavData(samples: samples, sampleRate: Int(sampleRate))
    }

    private static func wavData(samples: [Int16], sampleRate: Int) -> Data {
        let byteRate = sampleRate * 2
        let dataSize = samples.count * 2
        var data = Data()
        func append(_ s: String) { data.append(s.data(using: .ascii)!) }
        func appendLE(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func appendLE16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF")
        appendLE(UInt32(36 + dataSize))
        append("WAVE")
        append("fmt ")
        appendLE(16) // fmt chunk size
        appendLE16(1) // PCM
        appendLE16(1) // mono
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(byteRate))
        appendLE16(2) // block align
        appendLE16(16) // bits per sample
        append("data")
        appendLE(UInt32(dataSize))
        samples.withUnsafeBufferPointer { data.append(contentsOf: UnsafeRawBufferPointer($0)) }

        return data
    }
}

extension CallSoundPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.deactivateSession() }
    }
}
