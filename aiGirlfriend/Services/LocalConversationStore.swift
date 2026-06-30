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
        var xp: Int
        var level: Int
        var summary: String           // özetlenmiş eski mesajlar
        var summarizedCount: Int      // kaç mesaj özetlendi
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
