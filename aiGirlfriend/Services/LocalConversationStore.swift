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

        enum CodingKeys: String, CodingKey {
            case messages, xp, level, summary, summarizedCount, msgCounter, levelProgress, detectedLanguage
        }

        init(
            messages: [Message], xp: Int, level: Int, summary: String, summarizedCount: Int,
            msgCounter: Int = 0, levelProgress: Double = 0, detectedLanguage: String? = nil
        ) {
            self.messages = messages
            self.xp = xp
            self.level = level
            self.summary = summary
            self.summarizedCount = summarizedCount
            self.msgCounter = msgCounter
            self.levelProgress = levelProgress
            self.detectedLanguage = detectedLanguage
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
        }
    }

    // MARK: - Dosya yolu

    private func storeURL(for id: UUID) -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalConversations", isDirectory: true)
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

    func updateSummary(for id: UUID, summary: String, summarizedCount: Int) {
        guard var stored = load(for: id) else { return }
        stored.summary = summary
        stored.summarizedCount = summarizedCount
        save(stored, for: id)
    }
}
