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
    /// AKTİF (yüklü) mesaj — çalıyor VEYA duraklatılmış olabilir. Duraklatınca
    /// player canlı kalır (kaldığı yerden devam + duruyorken sarma için).
    var speakingMessageID: UUID?
    /// Şu an GERÇEKTEN çalıyor mu (duraklatılmış değil) — play/pause ikonu buna bakar.
    var isPlaying: Bool = false
    /// WhatsApp tarzı oynatma ilerlemesi (0...1) — çalan mesajın dalga-formu
    /// bu orana kadar "dolu" gösterilir (bkz. VoiceMessageBubble).
    var playbackProgress: Double = 0
    /// Geçen süre (saniye) — çalarken süre yazısı bunu gösterir (WhatsApp gibi).
    var playbackElapsed: Double = 0

    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var progressTimer: Timer?

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
        progressTimer?.invalidate()
        progressTimer = nil
        playbackProgress = 0
        playbackElapsed = 0
        isPlaying = false
        speakingMessageID = nil
    }

    /// Duraklat — player CANLI kalır (kaldığı yerden devam + duruyorken sarma
    /// için). speakingMessageID korunur ki balon hâlâ "aktif" görünsün.
    func pausePlayback() {
        player?.pause()
        isPlaying = false
        progressTimer?.invalidate()
        progressTimer = nil
    }

    /// Duraklatılmış sesi KALDIĞI YERDEN sürdürür (sıfırdan başlamaz).
    func resumePlayback() {
        guard let p = player else { return }
        p.play()
        isPlaying = true
        startProgressTimer()
    }

    /// Çalan sesi verilen orana (0...1) atlatır — dalga-formu üzerinde
    /// sürükleyerek ileri/geri sarma için (bkz. VoiceMessageBubble).
    func seek(to fraction: Double) {
        guard let p = player, p.duration > 0 else { return }
        let clamped = min(1, max(0, fraction))
        p.currentTime = clamped * p.duration
        playbackElapsed = p.currentTime
        playbackProgress = clamped
    }

    private func playData(_ data: Data) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            player = p
            playbackProgress = 0
            playbackElapsed = 0
            isPlaying = true
            p.play()
            startProgressTimer()
        } catch {
            speakingMessageID = nil
        }
    }

    /// 20 fps'lik hafif bir zamanlayıcı — çalan sesin currentTime/duration
    /// oranını yayınlar (bkz. playbackProgress). stop()/bitiş temizler.
    private func startProgressTimer() {
        progressTimer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                self.playbackElapsed = p.currentTime
                self.playbackProgress = p.duration > 0 ? min(1, p.currentTime / p.duration) : 0
            }
        }
        RunLoop.main.add(t, forMode: .common)
        progressTimer = t
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
        Task { @MainActor in
            self.progressTimer?.invalidate()
            self.progressTimer = nil
            self.playbackProgress = 0
            self.playbackElapsed = 0
            self.isPlaying = false
            self.speakingMessageID = nil
        }
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
    func synthesizeVoiceMessage(text: String, role: String, vibe: String, lang: String, useElevenLabs: Bool = false, voiceId: String? = nil) async -> TTSResult {
        var payload: [String: Any] = [
            "text": text, "role": role, "vibe": vibe, "lang": lang, "useElevenLabs": useElevenLabs,
        ]
        // DEV-curated characters (see dev-create-character) pin an exact
        // ElevenLabs voice — server uses it directly when present, else
        // falls back to the role+vibe map (bkz. voice-message-tts/index.ts).
        if let voiceId, !voiceId.isEmpty { payload["voiceId"] = voiceId }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return .failure }
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
    /// Play/pause tuşu: aynı mesaj çalıyorsa DURAKLAT, duraklatılmışsa KALDIĞI
    /// YERDEN SÜRDÜR, başka/yeni mesajsa baştan çal (bkz. kullanıcı talebi:
    /// "durdurup yeniden başlattığımda sıfırdan başlamamalı").
    func togglePlay(at relativePath: String, id: UUID) {
        if speakingMessageID == id, player != nil {
            if isPlaying { pausePlayback() } else { resumePlayback() }
        } else {
            playFile(at: relativePath, id: id)
        }
    }

    func playFile(at relativePath: String, id: UUID) {
        // Aynı mesaj ZATEN çalıyorsa yeniden başlatma — hızlı çift-dokunuş /
        // yeniden çizimde "iki tane ses" üst üste binmesin (bkz. kullanıcı
        // talebi: "ses istediğimde iki tane ses geliyor").
        if speakingMessageID == id, player?.isPlaying == true { return }
        stop()
        let url = VoicePlayer.voiceMessagesDirectory.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url) else { return }
        speakingMessageID = id
        playData(data)
    }
}
