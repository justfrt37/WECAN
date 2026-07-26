//
//  LocalConversationStore.swift
//  "SIFIR YEREL" (bkz. plan tender-cooking-bear): sohbet durumu artık DİSKE
//  YAZILMAZ. Bu tip yalnızca GEÇİCİ bir bellek-içi önbelleğe dönüştü — tek
//  doğru kaynak Supabase'dir (conversations + messages + durum sütunları, bkz.
//  migration 009). Her açılışta CharacterStore.hydrateConversations() bu
//  önbelleği sunucudan tazeler; uygulama silinip yüklenince önbellek boş başlar
//  ve yalnızca sunucuda olan geri gelir. Böylece "silinen sohbet diriliyor /
//  reinstall sonrası geri geliyor" hataları kökten biter.
//
//  API (load/save/clear/allCharacterIDs/clearAll/updateSummary) korundu ki
//  mevcut tüm çağrı yerleri değişmeden derlensin — yalnızca alt katman disk
//  yerine kilitli bir bellek-içi sözlük. userId ile isim-uzayı korunur (bir
//  anonim kullanıcının önbelleği yeniden-anonimleşme sonrası diğerine sızmasın).
//

import Foundation

final class LocalConversationStore {
    static let shared = LocalConversationStore()
    private init() {}

    // Eşzamanlı erişim (ör. ScheduleGenerator arka plan Task'ları) için kilit.
    private let lock = NSLock()
    private var mem: [String: [UUID: Stored]] = [:]
    private func userKey() -> String { UserDefaultsManager.shared.userId ?? "anonymous" }

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

    // MARK: - Yükle / Kaydet / Temizle (bellek-içi)

    func load(for id: UUID) -> Stored? {
        lock.lock(); defer { lock.unlock() }
        return mem[userKey()]?[id]
    }

    func save(_ stored: Stored, for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        mem[userKey(), default: [:]][id] = stored
    }

    func clear(for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        mem[userKey()]?[id] = nil
    }

    /// Bu oturumda (sunucudan hidrasyon + onboarding + gönderim) önbelleğe
    /// girmiş TÜM karakter ID'leri.
    func allCharacterIDs() -> [UUID] {
        lock.lock(); defer { lock.unlock() }
        return Array((mem[userKey()] ?? [:]).keys)
    }

    /// Tüm bellek-içi önbelleği temizler (mevcut kullanıcı için).
    func clearAll() {
        lock.lock(); defer { lock.unlock() }
        mem[userKey()] = [:]
    }

    // MARK: - Özet güncelle (özetleme tamamlandığında çağrılır)

    func updateSummary(for id: UUID, summary: String, summarizedCount: Int, schedule: CharacterSchedule? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard var stored = mem[userKey()]?[id] else { return }
        stored.summary = summary
        stored.summarizedCount = summarizedCount
        if let schedule { stored.schedule = schedule }
        mem[userKey(), default: [:]][id] = stored
    }
}
