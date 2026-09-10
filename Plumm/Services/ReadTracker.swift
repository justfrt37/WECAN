//
//  ReadTracker.swift
//  Karakter başına "buraya kadarını okudum" İŞARETİ — yerel, anlık katman.
//  Kalıcı gerçek sunucuda (`messages.is_read`, bkz. migration 031); bu ise
//  sunucu turu tamamlanmadan rozetin sönmesini sağlıyor.
//
//  SAYAÇTAN ZAMAN DAMGASINA GEÇTİ (2026-09-10) — ve sebebi ölçüldü.
//
//  Eskiden burada "görülen bot mesajı SAYISI" tutuluyordu ve rozet
//  `min(sunucu okunmamış, assistantCount − görülen)` ile hesaplanıyordu. İki
//  taraf AYNI ŞEYİ SAYMADIĞI için yerel taraf gerçek okunmamışı susturuyordu:
//    • `markReadNow` sayarken sentetik açılış mesajını ÇIKARIYOR
//      (realAssistantCount = ... − hasSyntheticOpening), sohbet listesi ise
//      sunucudaki tüm assistant satırlarını sayıyor — sentetik açılış varsa
//      iki sayı 1 farklı oluyor ve rozet HİÇ görünmüyordu.
//    • Yerel liste `image_request`/`voice_request` satırlarını filtreliyor,
//      sunucu listesi `voice_pending`/`image_pending`i sayıyor — kind'lar
//      değiştikçe fark yeniden açılıyordu (bkz. "unread badge sticking on
//      voice/photo messages" düzeltmelerinin de aynı kökten gelmesi).
//  Canlı doğrulama: sunucuda 26 assistant satırı / 1 okunmamış varken rozet 0
//  gösteriyordu.
//
//  Zaman damgası bu hata sınıfını YAPISAL olarak kapatıyor: artık sayı değil
//  MESAJ KİMLİĞİ karşılaştırılıyor — "bu tarihten yeni olan bot mesajı
//  okunmamıştır". Hangi kind'ın sayıldığı, sentetik mesaj olup olmadığı
//  önemsiz.
//

import Foundation

enum ReadTracker {
    /// Eski sayaç anahtarı — artık YAZILMIYOR, yalnızca temizlenmesi için
    /// duruyor. Aynı anahtarı yeni anlamla (zaman damgası) kullanmak, güncelleme
    /// yapan cihazlarda `Int` beklenen yerden `Double` okunmasına yol açardı.
    private static let legacyCountKey = "chat.seenCount"
    private static let key = "chat.lastReadAt"

    private static var map: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Kullanıcının bu karakterde "buraya kadar okudum" dediği an.
    /// `nil` = hiç işaretlenmemiş (yeni kurulum / temizlenmiş sohbet) → o
    /// durumda karar TAMAMEN sunucudaki `is_read`e bırakılır.
    static func lastReadAt(_ characterID: UUID) -> Date? {
        map[characterID.uuidString].map { Date(timeIntervalSince1970: $0) }
    }

    /// Şu ana kadarki her şeyi okundu işaretler.
    ///
    /// GERİYE GİTMEZ: aynı sohbete tekrar girip çıkmak damgayı ileri taşır,
    /// ama daha eski bir çağrı (ör. yarışan iki görünüm) damgayı geri çekemez.
    static func markRead(_ characterID: UUID, at date: Date = Date()) {
        var m = map
        let existing = m[characterID.uuidString] ?? 0
        m[characterID.uuidString] = max(existing, date.timeIntervalSince1970)
        map = m
    }

    /// Sohbet temizlendiğinde işareti kaldır — geçmiş silindiği için
    /// "buraya kadar okudum" bilgisi de anlamsız (bkz. ChatMaintenance).
    static func reset(_ characterID: UUID) {
        var m = map
        m.removeValue(forKey: characterID.uuidString)
        map = m
        // Eski sayaç kaydı da temizlensin ki güncelleme yapan cihazlarda
        // UserDefaults'ta ölü veri kalmasın.
        var legacy = UserDefaults.standard.dictionary(forKey: legacyCountKey) ?? [:]
        if legacy.removeValue(forKey: characterID.uuidString) != nil {
            UserDefaults.standard.set(legacy, forKey: legacyCountKey)
        }
    }
}
