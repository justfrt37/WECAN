//
//  SpeechRecognizer.swift
//  Cihaz içi konuşma → metin (iOS Speech framework). Ücretsiz, Türkçe.
//  Mikrofondan canlı dinler; durdurunca son metni verir.
//

import Foundation
import AVFoundation
import AudioToolbox
import Speech
import Observation

@MainActor
@Observable
final class SpeechRecognizer {
    var transcript = ""
    var isRecording = false
    var authorized = false

    /// Kayıt bitince (`stop()`) buradan ses dosyası okunur — kullanıcının
    /// KENDİ sesli mesajı olarak balon halinde oynatılabilir (bkz.
    /// ChatViewModel.sendUserVoice, VoicePlayer). Sadece transkript Grok'a
    /// gider, ses dosyası cihazda kalır.
    private(set) var recordedFileURL: URL?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))
        ?? SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recorder: AVAudioRecorder?

    /// İzinleri ister (mikrofon + konuşma tanıma).
    func requestAuthorization() async {
        let speechOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                c.resume(returning: status == .authorized)
            }
        }
        let micOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in c.resume(returning: granted) }
        }
        authorized = speechOK && micOK
    }

    @discardableResult
    func start() -> Bool {
        guard !isRecording else { return true }
        transcript = ""
        recordedFileURL = nil

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return false
        }

        // "Dinliyorum" sinyali — kullanıcıya kaydın gerçekten başladığını
        // hissettirir (bkz. plan: "listening cue").
        AudioServicesPlaySystemSound(1113)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }

        // Paralel AVAudioRecorder — kullanıcının kendi sesli mesaj balonu
        // için gerçek ses dosyasını (.m4a) yazar. SFSpeechAudioBufferRecognitionRequest
        // sadece tanıma motoruna gider, dosyaya yazmaz — bu yüzden ayrı recorder gerekli.
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("user-voice-\(UUID().uuidString).m4a")
        let recorderSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        recorder = try? AVAudioRecorder(url: fileURL, settings: recorderSettings)
        recorder?.record()

        audioEngine.prepare()
        do { try audioEngine.start() } catch { return false }
        isRecording = true

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                Task { @MainActor in self.transcript = result.bestTranscription.formattedString }
            }
            // SADECE `isFinal`de durdur. `error != nil` burada dahil edilmiyordu
            // ÖNCE hemen sonra kaldırıldı — SFSpeechRecognizer sık sık zararsız,
            // erken bir hata fırlatıyor (iyi bilinen quirk), bu da kaydı
            // görünmeden hemen kapatıp "mikrofon düğmesi hiçbir şey yapmıyor"
            // hissi veriyordu. Artık gerçek son (`stop()` çağrısıyla `endAudio()`)
            // dışında otomatik durmaz.
            if result?.isFinal ?? false {
                Task { @MainActor in self.stop() }
            }
        }
        return true
    }

    /// Kaydı durdurur. Son metni `transcript`'te, ses dosyasını `recordedFileURL`'de
    /// bırakır. ARTIK OTOMATIK GÖNDERMEZ — commit ChatView'daki açık Send
    /// aksiyonuyla olur (bkz. plan: recording overlay Cancel/Send).
    func stop() {
        guard isRecording else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        recorder?.stop()
        recordedFileURL = recorder?.url
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Kayıttan vazgeçer — overlay'in Cancel butonu. Dosyayı diskten siler,
    /// transkripti temizler, hiçbir yere göndermez.
    func cancel() {
        if isRecording { stop() }
        if let url = recordedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordedFileURL = nil
        transcript = ""
    }
}
