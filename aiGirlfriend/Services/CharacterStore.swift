//
//  CharacterStore.swift
//  Açılışta çekilen karakterleri uygulama boyunca tutar.
//

import Foundation
import Observation

@MainActor
@Observable
final class CharacterStore {
    var characters: [Character] = []
    var isLoaded = false
    var errorMessage: String?

    /// Feed'de o an görünen karakter (Chat sekmesi bunu kullanır).
    var currentCharacterID: UUID?

    /// O an cevap bekleyen ("yazıyor") karakterler — Chat History bunu gösterir.
    var typingCharacterIDs: Set<UUID> = []

    /// Karakter başına sohbet geçmişi önbelleği (Chat History'de doldurulur,
    /// ChatView anında açılsın diye — her seferinde yeniden yüklenmez).
    var chatCache: [UUID: [Message]] = [:]

    /// Keşfet'te "tanışmak ister misin?" onayından sonra MainTabView bunu
    /// görüp sohbete programatik olarak geçiş yapar (bkz. MeetRequest).
    var pendingMeetRequest: MeetRequest?

    /// Bildirime dokunulunca — belirli bir botun sohbetine değil, sadece
    /// Sohbetler sekmesine geçiş yapmak için (level-up dışındaki tüm bot bildirimleri).
    var pendingTab: MainTab?

    func setTyping(_ id: UUID, _ value: Bool) {
        if value { typingCharacterIDs.insert(id) } else { typingCharacterIDs.remove(id) }
    }

    var currentCharacter: Character? {
        if let id = currentCharacterID, let c = characters.first(where: { $0.id == id }) {
            return c
        }
        return characters.first
    }

    private let service = CharacterService()

    /// Karakter listesinin diskteki önbelleği — her açılışta sunucuyu beklemeden
    /// aynı anda göstermek için (splash "yükleniyor" ekranında takılmasın diye).
    private let cacheURL: URL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("characters_cache.json")

    /// Splash'te çağrılır. Hata olursa yedek (samples) ile devam eder ki
    /// uygulama boş ekranda takılmasın.
    func load() async {
        errorMessage = nil

        // 1) Diskteki önbellekten ANINDA göster — sunucu cevabını beklemeden.
        if let cached = loadCachedCharacters(), !cached.isEmpty {
            characters = cached
            isLoaded = true
        }

        // 2) Sunucudan taze veriyi çek, güncelle + önbelleğe yaz.
        do {
            let fetched = try await service.fetchAll()
            if !fetched.isEmpty {
                characters = fetched
                saveCachedCharacters(fetched)
            } else if characters.isEmpty {
                characters = Character.samples
            }
        } catch {
            errorMessage = error.localizedDescription
            if characters.isEmpty { characters = Character.samples }
        }

        // Tüm görselleri splash'te önceden indir ve cache'le; feed'de
        // "yükleniyor" görünmesin.
        var urls = characters.flatMap { [$0.photoURL, $0.avatarURL].compactMap { $0 } }
        urls += characters.flatMap { $0.galleryURLs }
        await ImageCache.shared.prefetch(Array(Set(urls)))

        isLoaded = true

        // Günlük rutinleri arka planda toplu üret — kullanıcı hiçbir sohbeti
        // AÇMADAN önce, splash'i bekletmeden (fire-and-forget). Böylece ilk
        // kez bir sohbete girince zaten "Online" yerine gerçek aktiviteyi görür.
        let charactersSnapshot = characters
        Task.detached(priority: .background) {
            await ScheduleGenerator.prewarmAll(characters: charactersSnapshot)
        }
    }

    private func loadCachedCharacters() -> [Character]? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode([Character].self, from: data)
    }

    private func saveCachedCharacters(_ chars: [Character]) {
        guard let data = try? JSONEncoder().encode(chars) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
