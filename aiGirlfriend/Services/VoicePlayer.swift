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

/// `synthesizeVoiceMessage`'ın sonucu — düz `Data?` yeterli değil çünkü
/// "yetersiz token" (402) ile GERÇEK bir üretim hatasını ayırt etmemiz
/// gerekiyor (bkz. ChatViewModel.sendVoiceRequest, farklı hata mesajları).
enum TTSResult {
    case success(Data, tokenBalance: Int?)
    case insufficientTokens
    case failure
}

extension TTSService {
    /// Sesli mesaj için tek seferlik sentez — role/vibe/lang'e göre 28 sesten
    /// birini seçer. Var olan `synthesize(text:)`'ten (yeniden-seslendirme,
    /// cihaz-içi fallback'li) FARKLI — burada fallback yok, başarısızlık gerçek hata.
    /// `voice-message-tts` Edge Function'ı çağırır — Google TTS anahtarı
    /// sunucuda (Supabase secret), istemcide hiç bulunmaz. Token bakiyesi
    /// bir JSON alanı değil, `X-Token-Balance` cevap başlığından okunur —
    /// başarı gövdesi ham ses baytları (bkz. voice-message-tts/index.ts).
    func synthesizeVoiceMessage(text: String, role: String, vibe: String, lang: String, useElevenLabs: Bool = false) async -> TTSResult {
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "text": text, "role": role, "vibe": vibe, "lang": lang, "useElevenLabs": useElevenLabs,
        ]) else { return .failure }
        var req = URLRequest(url: Config.voiceMessageTTSFunctionURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bearer = UserDefaultsManager.shared.accessToken ?? Config.supabaseAnonKey
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.httpBody = body
        req.timeoutInterval = 30

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse
        else { return .failure }

        if http.statusCode == 402 { return .insufficientTokens }
        guard http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.contains("audio") == true,
              !data.isEmpty
        else { return .failure }

        let balance = http.value(forHTTPHeaderField: "X-Token-Balance").flatMap(Int.init)
        return .success(data, tokenBalance: balance)
    }
}

extension VoicePlayer {
    /// Sesli mesaj dosyalarının kaydedildiği klasör (LocalConversationStore'un
    /// deseniyle aynı: Application Support altında, cihaz-yerel).
    static var voiceMessagesDirectory: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceMessages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Sentezlenen mp3'ü cihaza kaydeder, göreli dosya adını döner (Message.voiceLocalPath'e konur).
    static func saveVoiceMessage(_ data: Data, messageID: UUID) -> String? {
        let filename = "\(messageID.uuidString).mp3"
        let url = voiceMessagesDirectory.appendingPathComponent(filename)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return filename
    }

    /// Kaydedilmiş bir sesli mesajı çalar. `synthesize` YOK burada — dosya
    /// yoksa/bozuksa gerçek bir hata, robot-sese düşmüyoruz.
    func playFile(at relativePath: String, id: UUID) {
        stop()
        let url = VoicePlayer.voiceMessagesDirectory.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url) else { return }
        speakingMessageID = id
        playData(data)
    }
}
