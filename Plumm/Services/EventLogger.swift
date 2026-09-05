//
//  EventLogger.swift
//  Tek satırlık analytics logu — bkz. migration 026_event_log.sql. Amplitude/
//  PostHog yerine kendi `event_log` tablomuz: onboarding/paywall funnel'ı,
//  mesajlaşma aktivitesi, sekme geçişleri, özellik kullanımı buradan okunur
//  (bkz. kullanıcı talebi 2026-09-01).
//
//  Kullanım: `EventLogger.shared.log("paywall_shown", ["source": "onboarding"])`
//  — fire-and-forget, çağıranı asla bloklamaz. Yeni bir özellik eklendiğinde
//  tek satır `EventLogger.shared.log("feature_used", ["feature": "..."])`
//  yeterli, yeni event adı/şema değişikliği GEREKMEZ (bkz. `feature_used`).
//

import Foundation

final class EventLogger {
    static let shared = EventLogger()
    private init() {}

    private let lock = NSLock()
    private var buffer: [[String: Any]] = []
    private var flushTimer: Timer?

    /// Cihaz-kalıcı kimlik (bkz. UserDefaultsManager.deviceId) — aynı fiziksel
    /// cihazın reinstall'lar arası farklı `userId`'lerini birbirine bağlar.
    private let deviceId = UserDefaultsManager.shared.deviceId

    /// Bir "ziyaret"i (soğuk açılış ya da arka plandan dönüş) bir araya
    /// toplayan kimlik — `startNewSession()` ile yenilenir (bkz. PlummApp).
    private(set) var sessionId = UUID().uuidString

    private static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    /// Soğuk açılışta bir kez, `scenePhase` arka plandan `.active`'e her
    /// dönüşünde bir kez çağrılır (bkz. PlummApp.swift) — yeni bir "ziyaret"
    /// başlangıcını damgalar.
    func startNewSession() {
        lock.lock()
        sessionId = UUID().uuidString
        lock.unlock()
    }

    func log(_ name: String, _ properties: [String: Any] = [:]) {
        lock.lock()
        var row: [String: Any] = [
            "device_id": deviceId,
            "session_id": sessionId,
            "event_name": name,
            "properties": Self.jsonSafe(properties),
            "platform": "ios",
        ]
        if let userId = UserDefaultsManager.shared.userId { row["user_id"] = userId }
        if let v = Self.appVersion { row["app_version"] = v }
        buffer.append(row)
        let shouldFlushNow = buffer.count >= 20
        lock.unlock()

        if shouldFlushNow {
            flush()
        } else {
            scheduleFlush()
        }
    }

    /// 15sn'de bir (satır birikmişse) ya da arka plana geçişte (bkz. PlummApp)
    /// tetiklenir — böylece askıya alınan bir oturumdaki olaylar kaybolmaz.
    private func scheduleFlush() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.flushTimer == nil else { return }
            self.flushTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
                self?.flushTimer = nil
                self?.flush()
            }
        }
    }

    /// `[String: Any]` imzası her şeyi kabul ediyor ama JSONSerialization
    /// yalnızca String/NSNumber/Array/Dictionary/NSNull yazabiliyor. Tanımadığı
    /// bir tip görünce Swift hatası değil, Objective-C EXCEPTION fırlatıyor —
    /// yani `try?` onu YAKALAYAMAZ ve uygulama çöküyor.
    ///
    /// Canlı çökme: `character.id` bir UUID ve 13 çağrı yeri onu ham hâliyle
    /// geçiriyordu →
    /// `NSInvalidArgumentException: Invalid type in JSON write (__NSConcreteUUID)`.
    /// Tek tek çağrı yerlerini düzeltmek yerine burada temizliyoruz: 14. çağrıyı
    /// ekleyen kişi de aynı tuzağa düşmesin. Analytics'in kendi sözleşmesi de
    /// bunu gerektiriyor — "hiçbir kullanıcı akışını asla engellemez".
    private static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let v as String: return v
        case let v as NSNumber: return v          // Int/Double/Bool hepsi buraya düşer
        case let v as UUID: return v.uuidString
        case let v as URL: return v.absoluteString
        case let v as Date: return ISO8601DateFormatter().string(from: v)
        case let v as [Any]: return v.map(jsonSafe)
        case let v as [String: Any]: return v.mapValues(jsonSafe)
        case is NSNull: return NSNull()
        // Enum, struct, model — analytics için okunabilir hâli yeterli, veri
        // kaybetmektense metne çeviriyoruz.
        default: return String(describing: value)
        }
    }

    /// Uygulama arka plana geçerken (bkz. PlummApp scenePhase) çağrılır —
    /// zamanlayıcıyı beklemeden birikmiş her şeyi hemen gönderir.
    func flush() {
        lock.lock()
        guard !buffer.isEmpty else { lock.unlock(); return }
        let rows = buffer
        buffer.removeAll()
        lock.unlock()

        Task {
            guard let url = URL(string: "\(Config.supabaseURL)/rest/v1/event_log") else { return }
            var request = SupabaseRequest.post(url: url, bearer: SupabaseRequest.sessionBearer, timeout: 20)
            // Son savunma: jsonSafe her şeyi temizlemiş olmalı, ama serileştirme
            // ObjC exception fırlattığı için `try?` bir güvence DEĞİL — yazmadan
            // önce geçerliliği açıkça doğruluyoruz.
            guard JSONSerialization.isValidJSONObject(rows),
                  let body = try? JSONSerialization.data(withJSONObject: rows) else { return }
            request.httpBody = body
            // Sessizce yut — analytics hiçbir kullanıcı akışını asla engellemez/
            // uyarı göstermez, en kötü ihtimalle o parti kaybolur.
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}
