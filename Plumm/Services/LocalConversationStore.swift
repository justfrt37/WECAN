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
        lock.lock()
        mem[userKey(), default: [:]][id] = stored
        lock.unlock()
        // Seviyeyi KALICI önbelleğe de yaz — bellek-içi tablo uygulama yeniden
        // açılınca boş başlıyor (bkz. RelationshipLevelStore).
        RelationshipLevelStore.set(id, level: stored.level, progress: stored.levelProgress)
    }

    func clear(for id: UUID) {
        lock.lock()
        mem[userKey()]?[id] = nil
        lock.unlock()
        RelationshipLevelStore.remove(id)
    }

    /// Bu oturumda (sunucudan hidrasyon + onboarding + gönderim) önbelleğe
    /// girmiş TÜM karakter ID'leri.
    func allCharacterIDs() -> [UUID] {
        lock.lock(); defer { lock.unlock() }
        return Array((mem[userKey()] ?? [:]).keys)
    }

    /// Tüm bellek-içi önbelleği temizler (mevcut kullanıcı için).
    func clearAll() {
        lock.lock()
        mem[userKey()] = [:]
        lock.unlock()
        RelationshipLevelStore.removeAll()
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

    // MARK: - Yerinde güncelleme (tam Stored yeniden inşa etmeden)

    /// Var olan bir kayda TEK bir mesaj ekler — mevcut dizinin sonuna in-place
    /// append yapar, `Stored`'un TÜMÜNÜ yeniden inşa etmez. Kayıt bu karakter
    /// için henüz yoksa (ör. senkron ilk-selamdan sonraki ilk gerçek mesaj —
    /// bkz. ChatViewModel.attachFirstHello, synthetic:true dalı hiç save()
    /// çağırmıyor) `defaultLevel`/`defaultLevelProgress` ile SIFIRDAN bir
    /// kayıt oluşturur — eski `updateCache()`'in "stored yoksa da çalış"
    /// davranışıyla birebir.
    func appendMessage(_ message: Message, for id: UUID, defaultLevel: Int, defaultLevelProgress: Double) {
        lock.lock(); defer { lock.unlock() }
        let key = userKey()
        if mem[key]?[id] != nil {
            mem[key]?[id]?.messages.append(message)
        } else {
            mem[key, default: [:]][id] = Stored(
                messages: [message], xp: 0, level: defaultLevel, summary: "",
                summarizedCount: 0, levelProgress: defaultLevelProgress
            )
        }
    }

    /// Var olan bir mesajı id'sinden bulup yerinde günceller (ör. bekleyen
    /// bir foto/ses balonunun üretim sonucu gelince doldurulması) — tüm
    /// mesaj dizisini kopyalamadan tek elemanı mutate eder. Kayıt ya da
    /// mesaj bulunamazsa sessizce hiçbir şey yapmaz.
    func updateMessage(id: UUID, for characterId: UUID, mutate: (inout Message) -> Void) {
        lock.lock(); defer { lock.unlock() }
        let key = userKey()
        guard let idx = mem[key]?[characterId]?.messages.firstIndex(where: { $0.id == id }) else { return }
        mutate(&mem[key]![characterId]!.messages[idx])
    }

    /// Seviye/ilerleme/mesaj-sayacı alanlarını yerinde günceller — mesaj
    /// dizisine dokunmaz. Kayıt yoksa hiçbir şey yapmaz (bu üç alan sadece
    /// `applyPostReplyEffects`'ten, yani bir mesaj zaten eklenmiş bir turun
    /// sonunda çağrılır — kayıt bu noktada zaten var olmalı).
    func updateFields(for id: UUID, level: Int, levelProgress: Double, msgCounter: Int) {
        lock.lock(); defer { lock.unlock() }
        let key = userKey()
        guard mem[key]?[id] != nil else { return }
        mem[key]?[id]?.level = level
        mem[key]?[id]?.levelProgress = levelProgress
        mem[key]?[id]?.msgCounter = msgCounter
        RelationshipLevelStore.set(id, level: level, progress: levelProgress)
    }

    /// `detectedLanguage`'ı en son asistan mesajından yeniden hesaplar
    /// (bkz. ConversationLanguage.resolve) — SADECE yeni bir asistan mesajı
    /// eklendiği anlarda çağrılmalı (bkz. ChatViewModel call site'ları).
    /// Kayıt ya da asistan mesajı yoksa hiçbir şey yapmaz.
    func refreshDetectedLanguage(for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        let key = userKey()
        guard let latest = mem[key]?[id]?.messages.last(where: { $0.role == .assistant })?.content else { return }
        let previous = mem[key]?[id]?.detectedLanguage
        mem[key]?[id]?.detectedLanguage = ConversationLanguage.resolve(latestAssistantText: latest, previouslyDetected: previous)
    }

    /// "Sohbeti Temizle" yerel sıfırlama — mesajları/özeti/durumu HER ZAMAN
    /// sıfırlar (server ile birebir aynı alanlar — bkz. chat/index.ts clear
    /// branch); relationship_level/level_progress SADECE `keepLevel` false
    /// ise sıfırlanır. Memories/behaviors istemcide hiç tutulmuyor (sadece
    /// server tablosu) — bu yüzden bu fonksiyonun keepMemories/keepBehaviors
    /// parametresi yok, o iki bayrak sadece ChatService çağrısını etkiler.
    /// Kayıt bu karakter için hiç yoksa hiçbir şey yapmaz.
    func resetKeeping(for id: UUID, keepLevel: Bool) {
        lock.lock(); defer { lock.unlock() }
        let key = userKey()
        guard mem[key]?[id] != nil else { return }
        mem[key]?[id]?.messages = []
        mem[key]?[id]?.summary = ""
        mem[key]?[id]?.summarizedCount = 0
        mem[key]?[id]?.schedule = nil
        mem[key]?[id]?.wokenUpAt = nil
        mem[key]?[id]?.manualSleepAt = nil
        mem[key]?[id]?.ghostedAt = nil
        mem[key]?[id]?.detectedLanguage = nil
        if !keepLevel {
            mem[key]?[id]?.level = 1
            mem[key]?[id]?.levelProgress = 0
            RelationshipLevelStore.set(id, level: 1, progress: 0)
        }
    }

    /// Belirli bir mesajı kayıttan kaldırır — retrySend'in başarısız mesajı
    /// silip aynı içerikle yenisini eklemesi için (bkz. ChatViewModel.retrySend).
    /// Kayıt ya da mesaj bulunamazsa hiçbir şey yapmaz.
    func removeMessage(id: UUID, for characterId: UUID) {
        lock.lock(); defer { lock.unlock() }
        let key = userKey()
        mem[key]?[characterId]?.messages.removeAll(where: { $0.id == id })
    }
}
