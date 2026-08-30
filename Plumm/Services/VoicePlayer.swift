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
final class VoicePlayer: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
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

    override init() {
        super.init()
        // Cihaz-içi TTS (fallback) bitişini yakalamak için — bkz. speakOnDevice /
        // speechSynthesizer(_:didFinish:). Aksi halde speakingMessageID hemen
        // temizlenip "konuşuyor" durumu HİÇ gösterilmiyordu.
        synth.delegate = self
    }

    // Not: zamanlayıcı sızıntısına karşı temizlik `stop()`'ta yapılır; bu da
    // ChatView.onDisappear'da çağrılır (main-actor izole `progressTimer`'a
    // nonisolated `deinit`'ten erişilemediği için ayrı bir deinit YOK).

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

    /// Oynatma durumunu (zamanlayıcı + ilerleme + aktif mesaj) sıfırlar.
    /// `stop()` ve oynatma bitiş delegesi aynı alanları temizliyordu.
    private func resetPlaybackState() {
        progressTimer?.invalidate()
        progressTimer = nil
        playbackProgress = 0
        playbackElapsed = 0
        isPlaying = false
        speakingMessageID = nil
    }

    /// Ses oturumunu bırak — .playback + .duckOthers ile başka uygulamaların
    /// sesini kalıcı kısık bırakmayalım (bkz. playData/speakOnDevice setActive(true)).
    private static func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        resetPlaybackState()
        Self.deactivateAudioSession()
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
        isPlaying = true
        synth.speak(u)
        // speakingMessageID BURADA temizlenmez — konuşma bitişi
        // speechSynthesizer(_:didFinish:) delegesinden temizlenir, aksi halde
        // cihaz-içi TTS "konuşuyor" durumunu HİÇ göstermiyordu.
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.resetPlaybackState()
            Self.deactivateAudioSession()
        }
    }

    /// Cihaz-içi (fallback) TTS bitince çağrılır — speakingMessageID'yi burada
    /// temizleriz ki konuşma boyunca "konuşuyor" durumu gösterilebilsin (bkz. speakOnDevice).
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isPlaying = false
            self.speakingMessageID = nil
            Self.deactivateAudioSession()
        }
    }
}

/// Sunucudaki "tts" Edge Function'ı çağırır. Anahtar yoksa nil döner (fallback).
struct TTSService {
    /// Ortak POST kurucusu (JSON gövde + Supabase auth başlıkları) — iki TTS
    /// çağrısı da aynı yedi satırı tekrarlıyordu.
    fileprivate static func request(url: URL, payload: [String: Any], timeout: TimeInterval) -> URLRequest? {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var req = SupabaseRequest.post(url: url, bearer: SupabaseRequest.sessionBearer, timeout: timeout)
        req.httpBody = body
        return req
    }

    func synthesize(text: String) async -> Data? {
        guard let url = URL(string: "\(Config.supabaseURL)/functions/v1/tts"),
              let req = Self.request(url: url, payload: ["text": text], timeout: 20) else { return nil }

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
    /// `voiceURL`: sunucunun Storage'a yüklediği kalıcı ses URL'i (reload'da ses
    /// buradan gelir). Upload başarısızsa nil — anlık çalma yerel `Data` ile yine olur.
    case success(Data, tokenBalance: Int?, voiceURL: URL?)
    case insufficientTokens
    /// Sunucu 403: ses Pro+ / Pro Max hakkı, bu abonelikte yok (bkz.
    /// _shared/entitlements.ts). Hata mesajı değil, paywall gösterilir.
    case notEntitled
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
        // Characters with an explicitly pinned ElevenLabs voice — server
        // uses it directly when present, else falls back to the role+vibe
        // map (bkz. voice-message-tts/index.ts).
        if let voiceId, !voiceId.isEmpty { payload["voiceId"] = voiceId }
        guard let req = Self.request(url: Config.voiceMessageTTSFunctionURL, payload: payload, timeout: 30)
        else { return .failure }

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse
        else { return .failure }

        if http.statusCode == 402 { return .insufficientTokens }
        if http.statusCode == 403 { return .notEntitled }
        guard http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.contains("audio") == true,
              !data.isEmpty
        else { return .failure }

        let balance = http.value(forHTTPHeaderField: "X-Token-Balance").flatMap(Int.init)
        let voiceURL = http.value(forHTTPHeaderField: "X-Voice-Url").flatMap { $0.isEmpty ? nil : URL(string: $0) }
        return .success(data, tokenBalance: balance, voiceURL: voiceURL)
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

    /// Reload'da sunucudan gelen sesli mesaj (`Message.voiceRemoteURL`) — yerel
    /// dosya yoksa bir kez indirip cache'ler, sonra yerel dosya gibi çalar.
    /// togglePlay davranışı (duraklat/sürdür/baştan) korunur.
    func togglePlay(remoteURL: URL, id: UUID) {
        if speakingMessageID == id, player != nil {
            if isPlaying { pausePlayback() } else { resumePlayback() }
            return
        }
        let filename = "\(id.uuidString).mp3"
        let localURL = VoicePlayer.voiceMessagesDirectory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: localURL.path) {
            playFile(at: filename, id: id)
            return
        }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: remoteURL) else { return }
            try? data.write(to: localURL, options: .atomic)
            playFile(at: filename, id: id)
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
