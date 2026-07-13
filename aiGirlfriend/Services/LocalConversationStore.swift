//
//  LocalConversationStore.swift
//  Kullanıcı tarafından oluşturulan karakterlerin sohbet geçmişini
//  cihaz üzerinde (Application Support) saklar. Supabase messages tablosu kullanılmaz.
//
//  Özet sistemi: her 20 mesajda bir eski mesajlar özetlenir (sunucu modunu aynalar).
//  Yapı: summary (sıkıştırılmış geçmiş) + son 20 mesaj → AI'a gönderilir.
//

import Foundation

final class LocalConversationStore {
    static let shared = LocalConversationStore()
    private init() {}

    struct Stored: Codable {
        var messages: [Message]       // tüm gerçek mesajlar (görüntüleme için)
        var xp: Int                   // eski mutlak XP alanı — artık kullanılmıyor, geriye dönük uyum için duruyor
        var level: Int
        var summary: String           // özetlenmiş eski mesajlar
        var summarizedCount: Int      // kaç mesaj özetlendi
        var msgCounter: Int = 0       // terfi eşiği için mesaj sayacı (istemci taraflı)
        var levelProgress: Double = 0 // güncel seviyenin ne kadarı tamamlandı (0...1), bkz. RelationshipXP
        /// Sohbetin GERÇEKTE hangi dilde geçtiğine dair son tahmin ("tr"/"en") —
        /// bildirim içeriği (JealousyContent vb.) bunu kullanır. Bkz. ConversationLanguage.
        var detectedLanguage: String?
        /// Bu (kullanıcı, karakter) sohbetine özel günlük rutin — bkz.
        /// CharacterSchedule, ChatViewModel.ensureScheduleGenerated. Eski
        /// kayıtlarda yok, `nil` olarak decode edilir.
        var schedule: CharacterSchedule?
        /// Karakter uykudayken mesaj alıp uyandırıldıysa o anın zamanı — bkz.
        /// CharacterSleepState, ChatViewModel.handleWakeUpIfAsleep. `nil` =
        /// uyandırma geçersiz (normal programa göre uyanık ya da hâlâ uyuyor).
        var wokenUpAt: Date?
        /// Kullanıcı gerçek yatma saatine yakınken uyumasını istedi ve karakter
        /// kabul etti — bkz. chat/index.ts wentToSleep. `nil` = erken-uyuma
        /// geçersiz.
        var manualSleepAt: Date?
        /// Ghosted bildirimi bu karaktere enjekte edildiği an — bkz.
        /// NotificationDelegate.injectMessage(kind: .ghosted). Doluyken bu
        /// karakter hiçbir proaktif bildirim göndermez (jealousy/bedtime/
        /// level-up) — kullanıcı tekrar yazana kadar sessiz kalır (bkz.
        /// NotificationScheduler.noteUserSent, orada `nil`lenir).
        var ghostedAt: Date?

        enum CodingKeys: String, CodingKey {
            case messages, xp, level, summary, summarizedCount, msgCounter, levelProgress,
                 detectedLanguage, schedule, wokenUpAt, manualSleepAt, ghostedAt
        }

        init(
            messages: [Message], xp: Int, level: Int, summary: String, summarizedCount: Int,
            msgCounter: Int = 0, levelProgress: Double = 0, detectedLanguage: String? = nil,
            schedule: CharacterSchedule? = nil, wokenUpAt: Date? = nil, manualSleepAt: Date? = nil,
            ghostedAt: Date? = nil
        ) {
            self.messages = messages
            self.xp = xp
            self.level = level
            self.summary = summary
            self.summarizedCount = summarizedCount
            self.msgCounter = msgCounter
            self.levelProgress = levelProgress
            self.detectedLanguage = detectedLanguage
            self.schedule = schedule
            self.wokenUpAt = wokenUpAt
            self.manualSleepAt = manualSleepAt
            self.ghostedAt = ghostedAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            messages = try c.decode([Message].self, forKey: .messages)
            xp = try c.decode(Int.self, forKey: .xp)
            level = try c.decode(Int.self, forKey: .level)
            summary = try c.decode(String.self, forKey: .summary)
            summarizedCount = try c.decode(Int.self, forKey: .summarizedCount)
            // Eski kayıtlarda yok — 0'dan başlar (küçük bir kozmetik sıfırlama, sorun değil).
            msgCounter = (try? c.decode(Int.self, forKey: .msgCounter)) ?? 0
            levelProgress = (try? c.decode(Double.self, forKey: .levelProgress)) ?? 0
            detectedLanguage = try? c.decode(String.self, forKey: .detectedLanguage)
            schedule = try? c.decodeIfPresent(CharacterSchedule.self, forKey: .schedule)
            wokenUpAt = try? c.decodeIfPresent(Date.self, forKey: .wokenUpAt)
            manualSleepAt = try? c.decodeIfPresent(Date.self, forKey: .manualSleepAt)
            ghostedAt = try? c.decodeIfPresent(Date.self, forKey: .ghostedAt)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(messages, forKey: .messages)
            try c.encode(xp, forKey: .xp)
            try c.encode(level, forKey: .level)
            try c.encode(summary, forKey: .summary)
            try c.encode(summarizedCount, forKey: .summarizedCount)
            try c.encode(msgCounter, forKey: .msgCounter)
            try c.encode(levelProgress, forKey: .levelProgress)
            try c.encodeIfPresent(detectedLanguage, forKey: .detectedLanguage)
            try c.encodeIfPresent(schedule, forKey: .schedule)
            try c.encodeIfPresent(wokenUpAt, forKey: .wokenUpAt)
            try c.encodeIfPresent(ghostedAt, forKey: .ghostedAt)
            try c.encodeIfPresent(manualSleepAt, forKey: .manualSleepAt)
        }
    }

    // MARK: - Dosya yolu

    // Namespaced by the current Supabase userId — without this, a silent
    // re-anonymization (expired refresh token → brand-new anonymous userId)
    // left the NEW account reading the PREVIOUS account's local chat files
    // (character UUIDs are stable/shared, so every character looked like it
    // already had a chat, emptying Discover and faking the matches list).
    private func storeURL(for id: UUID) -> URL {
        let userId = UserDefaultsManager.shared.userId ?? "anonymous"
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalConversations", isDirectory: true)
            .appendingPathComponent(userId, isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Yükle / Kaydet / Temizle

    func load(for id: UUID) -> Stored? {
        guard let data = try? Data(contentsOf: storeURL(for: id)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }
        return stored
    }

    func save(_ stored: Stored, for id: UUID) {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: storeURL(for: id), options: .atomic)
    }

    func clear(for id: UUID) {
        try? FileManager.default.removeItem(at: storeURL(for: id))
    }

    // MARK: - Özet güncelle (özetleme tamamlandığında çağrılır)

    func updateSummary(for id: UUID, summary: String, summarizedCount: Int, schedule: CharacterSchedule? = nil) {
        guard var stored = load(for: id) else { return }
        stored.summary = summary
        stored.summarizedCount = summarizedCount
        if let schedule { stored.schedule = schedule }
        save(stored, for: id)
    }
}
