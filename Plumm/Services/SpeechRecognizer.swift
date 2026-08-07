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

    // TEMP DEBUG — remove once voice call pipeline is verified on device.
    var onDebug: ((String) -> Void)?

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
    /// Mirrors the `configuresSession` a caller passed to the most recent
    /// `start()` — `stop()` reads this so it only deactivates the shared
    /// audio session when THIS instance is the one that activated it.
    /// Without this, CallViewModel's mid-call `recognizer.cancel()` (barge-in
    /// cleanup, mute) would deactivate the whole call's duplex session, not
    /// just this recognition pass.
    private var lastStartConfiguredSession = true

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

    /// `configuresSession: false` skips the `.record`-category session setup —
    /// used by CallViewModel, which owns a single `.playAndRecord`/`.voiceChat`
    /// session for the whole call (duplex: listens while the AI is speaking for
    /// barge-in). The normal tap-to-record voice-note flow (ChatView) always
    /// passes the default `true`, unchanged.
    @discardableResult
    func start(configuresSession: Bool = true, playStartCue: Bool = true) -> Bool {
        guard !isRecording else { onDebug?("recognizer.start: already recording"); return true }
        transcript = ""
        recordedFileURL = nil
        onDebug?("recognizer.start called (configuresSession: \(configuresSession))")

        if configuresSession {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                onDebug?("recognizer.start: session config failed: \(error)")
                return false
            }
        }
        lastStartConfiguredSession = configuresSession

        // "Dinliyorum" sinyali — kullanıcıya kaydın gerçekten başladığını
        // hissettirir (bkz. plan: "listening cue"). Barge-in's silent background
        // listener (started the instant AI audio begins playing) passes
        // playStartCue: false — otherwise it'd tick on every single AI reply.
        if playStartCue { AudioServicesPlaySystemSound(1113) }

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
        do {
            try audioEngine.start()
            onDebug?("audioEngine started OK, input format: \(format)")
        } catch {
            onDebug?("audioEngine.start FAILED: \(error)")
            // start() başarısız olursa tap + recorder ZATEN kurulmuş durumda kalır;
            // temizlemezsek bir sonraki start() aynı bus'a İKİNCİ bir tap kurup
            // AVAudioEngine'i çökertir (fatal). O yüzden burada tam geri sar:
            // tap kaldır, recorder durdur/nil'le, request/task iptal, ses oturumunu
            // bırak ve durumu sıfırla.
            audioEngine.inputNode.removeTap(onBus: 0)
            recorder?.stop()
            recorder = nil
            request?.endAudio()
            request = nil
            isRecording = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            return false
        }
        isRecording = true

        if recognizer == nil { onDebug?("SFSpeechRecognizer is nil (locale unsupported?)") }
        else if recognizer?.isAvailable == false { onDebug?("SFSpeechRecognizer.isAvailable == false") }

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in self.onDebug?("recognitionTask error: \(error)") }
            }
            if let result {
                let partial = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.transcript = partial
                    self.onDebug?("partial transcript: \"\(partial)\" (isFinal: \(result.isFinal))")
                }
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
        if lastStartConfiguredSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
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
