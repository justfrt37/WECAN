//
//  AnalyticsService.swift
//  Amplitude örneğinin tek sahibi — SDK burada BİR KEZ başlatılır.
//
//  OLAYLAR BURADAN DEĞİL, EventLogger'DAN GELİYOR. `EventLogger.shared.log(...)`
//  hem kendi `event_log` tablomuza hem de buraya yazıyor (bkz. EventLogger.log).
//  Sebep: uygulamada zaten 23 olay adı ve ~35 çağrı yeri var (onboarding,
//  paywall, mesajlaşma, karakter yaratma); bunları Amplitude için ikinci kez
//  elle yazmak iki taksonominin zamanla birbirinden ayrılması demekti — bir
//  tarafta düzeltilen bir olay adı diğer tarafta eski kalır ve funnel sessizce
//  bozulur. Tek çağrı noktası bu riski yapısal olarak kaldırıyor.
//

import AmplitudeUnified
import Foundation
import OSLog

final class AnalyticsService {
    static let shared = AnalyticsService()
    private static let diag = Logger(subsystem: "com.firat.Plumm", category: "analytics")

    private let amplitude: Amplitude

    /// Amplitude'a bildirilmiş son kullanıcı kimliği. `identify` her açılışta
    /// ve her öne gelişte çağrılabildiği için aynı değeri tekrar yazmayı
    /// engelliyor (her setUserId bir identify isteği demek).
    private var reportedUserId: String?

    private init() {
        let analyticsConfig = AnalyticsConfig(
            autocapture: [.sessions, .appLifecycles, .screenViews]
        )
        let sessionReplayConfig = SessionReplayPlugin.Config(sampleRate: 1.0)

        amplitude = Amplitude(
            apiKey: Config.amplitudeAPIKey,
            analyticsConfig: analyticsConfig,
            sessionReplayConfig: sessionReplayConfig
        )

        // KİMLİK EŞLEMESİ — funnel'ın çalışması için şart.
        //
        // Amplitude kendi başına rastgele bir deviceId üretiyor; bizim
        // `UserDefaultsManager.deviceId`i ona VERMEZSEK aynı fiziksel cihaz
        // iki sistemde iki farklı kimlikle görünür ve `event_log` ile Amplitude
        // karşılaştırılamaz hale gelir. Kullanıcı kimliği ise açılışta henüz
        // yok (anonim giriş sonra tamamlanıyor), o yüzden `identify` ile
        // sonradan bağlanıyor (bkz. PlummApp).
        amplitude.setDeviceId(deviceId: UserDefaultsManager.shared.deviceId)
        identify()
    }

    /// Supabase kullanıcı kimliğini Amplitude'a bağlar. Anonim giriş
    /// tamamlandıktan sonra çağrılmalı — o ana kadar `userId` nil.
    ///
    /// Aynı uid'yi ikinci kez yazmıyor: idempotent olması, PlummApp'in her
    /// `.active` geçişinde çağırmasını ucuz kılıyor.
    func identify() {
        guard let uid = UserDefaultsManager.shared.userId, uid != reportedUserId else { return }
        reportedUserId = uid
        amplitude.setUserId(userId: uid)
        Self.diag.log("amplitude userId baglandi: \(uid, privacy: .public)")
    }

    /// EventLogger'ın Amplitude ayağı. Doğrudan çağırmayın —
    /// `EventLogger.shared.log(...)` kullanın ki olay hem kendi tablomuza hem
    /// buraya gitsin.
    ///
    /// `sessionId` özellik olarak ekleniyor: Amplitude'un kendi oturum kavramı
    /// var (autocapture .sessions) ama bizim `event_log`daki oturumla
    /// eşleştirmek için bizimkine de ihtiyaç var — bir funnel adımı şüpheli
    /// göründüğünde iki tarafı aynı oturum üzerinden karşılaştırabilmek için.
    func track(_ name: String, _ properties: [String: Any]) {
        var props = properties
        props["session_id"] = EventLogger.shared.sessionId
        amplitude.track(eventType: name, eventProperties: props)
    }

    /// Uygulama arka plana geçerken (bkz. PlummApp scenePhase) — birikmiş
    /// olayları beklemeden gönderir, askıya alınan oturumda kaybolmasınlar.
    func flush() {
        amplitude.flush()
    }
}
