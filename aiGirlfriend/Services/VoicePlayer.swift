//
//  VoicePlayer.swift
//  Kızın cevabını seslendirir.
//  Önce sunucudaki "tts" Edge Function (kaliteli API sesi) denenir;
//  anahtar yok/başarısızsa cihaz içi AVSpeechSynthesizer'a düşer (ücretsiz).
//

import Foundation
import AVFoundation
import Observation

@MainActor
@Observable
final class VoicePlayer: NSObject, AVAudioPlayerDelegate {
    var speakingMessageID: UUID?

    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?

    func speak(_ text: String, id: UUID) {
        stop()
        speakingMessageID = id
        Task {
            if let data = await TTSService().synthesize(text: text) {
                playData(data)
            } else {
                speakOnDevice(text)
            }
        }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        speakingMessageID = nil
    }

    private func playData(_ data: Data) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(data: data)
            player?.delegate = self
            player?.play()
        } catch {
            speakingMessageID = nil
        }
    }

    private func speakOnDevice(_ text: String) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .duckOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "tr-TR") ?? AVSpeechSynthesisVoice(language: "en-US")
        u.rate = 0.5
        synth.speak(u)
        // Cihaz içi seste bitişi basitçe işaretlemiyoruz; UI durumu kısa sürer.
        speakingMessageID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.speakingMessageID = nil }
    }
}

/// Sunucudaki "tts" Edge Function'ı çağırır. Anahtar yoksa nil döner (fallback).
struct TTSService {
    func synthesize(text: String) async -> Data? {
        guard let url = URL(string: "\(Config.supabaseURL)/functions/v1/tts"),
              let body = try? JSONSerialization.data(withJSONObject: ["text": text]) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bearer = UserDefaultsManager.shared.accessToken ?? Config.supabaseAnonKey
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.httpBody = body
        req.timeoutInterval = 20

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.contains("audio") == true,
              !data.isEmpty
        else { return nil }
        return data
    }
}
