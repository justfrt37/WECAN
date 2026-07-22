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

    /// Bumped any time a message is injected into LocalConversationStore
    /// OUTSIDE the normal ChatViewModel send/receive flow (bot notifications,
    /// photo-download reactions) — ChatListView observes this to reload/
    /// reorder even when nothing touched `typingCharacterIDs`.
    var conversationsVersion: Int = 0

    /// Keşfet'te "tanışmak ister misin?" onayından sonra MainTabView bunu
    /// görüp sohbete programatik olarak geçiş yapar (bkz. MeetRequest).
    var pendingMeetRequest: MeetRequest?

    /// Bildirime dokunulunca — belirli bir botun sohbetine değil, sadece
    /// Sohbetler sekmesine geçiş yapmak için (level-up dışındaki tüm bot bildirimleri).
    var pendingTab: MainTab?

    /// Sohbet listesinden bir satıra dokununca — MainTabView bunu görüp o
    /// karakterin sohbetine programatik geçer (NavigationLink yerine, çünkü
    /// satırda özel swipe/tap davranışı var, bkz. ChatListView.SwipeToDeleteRow).
    var pendingChatCharacter: Character?

    /// Onboarding'te seçilen karakterin ilk-selamı. ChatViewModel bunu görünce
    /// mesajı ANINDA değil, normal "yazıyor" (3 nokta) animasyonuyla gösterir —
    /// mesaj sunucuya zaten kalıcı yazıldı (bkz. MainTabView.openPendingOnboardingChat).
    var pendingFirstHello: (characterID: UUID, line: String)?

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

        // "Sıfır yerel" geçişi: önceki sürümlerden kalan DİSK sohbet verilerini
        // tek seferlik temizle (artık hiçbir şey diske yazmıyoruz — bkz.
        // LocalConversationStore). Böylece yükseltme yapan kullanıcıda eski
        // dosyalar sessizce ortada kalıp kafa karıştırmaz.
        Self.purgeLegacyLocalData()

        // 1) Diskteki önbellekten ANINDA göster — sunucu cevabını beklemeden.
        if let cached = loadCachedCharacters(), !cached.isEmpty {
            characters = cached
            isLoaded = true
        }

        // 2) Sunucudan taze veriyi çek, güncelle + önbelleğe yaz. Tek seferlik
        // bir ağ hatası yüzünden BAYAT önbellek sessizce kalıcı gösterilmesin
        // (ör. yeni oluşturulmuş/yeniden atanmış karakterler asla görünmez)
        // — birkaç kez dene, sonra pes et.
        var fetched: [Character]?
        for attempt in 1...3 {
            do {
                fetched = try await service.fetchAll()
                break
            } catch {
                errorMessage = error.localizedDescription
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt - 1)) * 1_000_000_000))
                }
            }
        }
        if let fetched, !fetched.isEmpty {
            characters = fetched
            saveCachedCharacters(fetched)
        } else if characters.isEmpty {
            characters = Character.samples
        }

        // Tüm görselleri splash'te önceden indir ve cache'le; feed'de
        // "yükleniyor" görünmesin.
        var urls = characters.flatMap { [$0.photoURL, $0.avatarURL].compactMap { $0 } }
        urls += characters.flatMap { $0.galleryURLs }
        await ImageCache.shared.prefetch(Array(Set(urls)))

        isLoaded = true

        // "Sıfır yerel": sohbet durumunu SUNUCUDAN bellek-içi önbelleğe doldur
        // (bkz. hydrateConversations / LocalConversationStore). Diğer ekranlar
        // (Keşfet "zaten konuşuyor" filtresi, Beğeniler, bildirim gating) bu
        // önbelleği okur — açılışta boş kalmasın diye burada tazelenir.
        // NOT: eski toplu rutin ön-üretimi (ScheduleGenerator.prewarmAll)
        // KALDIRILDI — rutin artık yalnızca disk'te değil bellekte tutulduğu
        // için her açılışta yeniden üretmek pahalı olurdu; rutin artık sohbet
        // AÇILDIĞINDA talep üzerine üretilir (bkz. ChatViewModel.ensureScheduleGenerated).
        await hydrateConversations()
    }

    private let conversationsService = ConversationsService()

    /// Eski (disk-tabanlı) sohbet verisini kaldırır — bir kez, sessizce.
    private static func purgeLegacyLocalData() {
        let fm = FileManager.default
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? fm.removeItem(at: support.appendingPathComponent("LocalConversations", isDirectory: true))
        }
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? fm.removeItem(at: caches.appendingPathComponent("chatlist_cache.json"))
        }
        UserDefaults.standard.removeObject(forKey: "chatlist.deleted.tombstones.v1")
    }

    /// "Sıfır yerel": bellek-içi LocalConversationStore'u tamamen SUNUCUDAN
    /// (conversations + messages, migration 009 durum sütunları dahil) yeniden
    /// doldurur. Diske hiçbir şey yazılmaz; uygulama silinince önbellek boş
    /// başlar ve yalnızca sunucuda olan geri gelir.
    func hydrateConversations() async {
        async let statesT = conversationsService.fetchConversationStates()
        async let msgsT = conversationsService.fetchAllMessages()
        let (states, msgs) = await (statesT, msgsT)

        var byConv: [UUID: [LastMessage]] = [:]
        for m in msgs { byConv[m.conversationID, default: []].append(m) }

        func parseDate(_ s: String?) -> Date? {
            guard let s else { return nil }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }

        for state in states {
            // desc → asc (görüntüleme/sayım sırası)
            let convMsgs = Array((byConv[state.id] ?? []).reversed())
            let messages: [Message] = convMsgs.map {
                Message(role: ChatRole(rawValue: $0.role) ?? .assistant,
                        content: $0.content, createdAt: $0.date ?? Date())
            }
            let existing = LocalConversationStore.shared.load(for: state.characterID)
            let stored = LocalConversationStore.Stored(
                messages: messages,
                xp: 0,
                level: state.relationshipLevel ?? existing?.level ?? 1,
                summary: state.summary ?? "",
                summarizedCount: state.summarizedCount ?? 0,
                msgCounter: existing?.msgCounter ?? 0,
                levelProgress: state.levelProgress ?? 0,
                detectedLanguage: state.detectedLanguage ?? existing?.detectedLanguage,
                // Sunucu rutini (schedule) henüz saklamıyor (bkz. Phase C) →
                // talep üzerine üretilmiş bellek-içi rutini KORU.
                schedule: state.schedule ?? existing?.schedule,
                wokenUpAt: parseDate(state.wokenUpAt) ?? existing?.wokenUpAt,
                manualSleepAt: parseDate(state.manualSleepAt) ?? existing?.manualSleepAt,
                ghostedAt: parseDate(state.ghostedAt)
            )
            LocalConversationStore.shared.save(stored, for: state.characterID)
        }
        conversationsVersion += 1
    }

    /// Foreground refresh — NOT the initial `load()` (no cache-first flash,
    /// no image prefetch, no schedule prewarm, no splash). Called every time
    /// the app becomes active (cold launch AND resuming from background) so
    /// newly-added characters (bkz. DEV curated-character creation) show up
    /// in Discover/Explore without needing a reinstall or full relaunch —
    /// `store.characters` is `@Observable`, so both views update the moment
    /// this replaces it, no per-view refresh code needed.
    func refreshCharacters() async {
        guard isLoaded else { return } // avoid racing the initial load()
        if let fetched = try? await service.fetchAll(), !fetched.isEmpty {
            characters = fetched
            saveCachedCharacters(fetched)
        }
        // Öne gelişte sohbet durumunu da sunucudan tazele — bir bildirim
        // (proaktif mesaj, bkz. Phase C) arka planda sunucuya yazılmış olabilir.
        await hydrateConversations()
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
