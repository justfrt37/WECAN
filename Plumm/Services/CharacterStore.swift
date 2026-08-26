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

    /// `load()` TAMAMEN bitti mi (sunucu fetch + hydrateConversations dahil).
    /// `isLoaded` yalnızca UI kapısı için ERKEN set edilir (disk önbelleği varsa
    /// splash beklemesin diye) — o pencerede bir öne-geliş `refreshCharacters()`
    /// çağrısı, henüz süren ilk yükleme boru hattıyla YARIŞIP çift fetch/hydrate
    /// (conversationsVersion iki kez artması) yapıyordu. refreshCharacters bu
    /// bayrağı bekler; gerçek bitişi işaretler.
    private var didFinishInitialLoad = false

    /// Feed'de o an görünen karakter (Chat sekmesi bunu kullanır).
    var currentCharacterID: UUID?

    /// O an cevap bekleyen ("yazıyor") karakterler — Chat History bunu gösterir.
    var typingCharacterIDs: Set<UUID> = []

    /// Karakter başına sohbet geçmişi önbelleği (Chat History'de doldurulur,
    /// ChatView anında açılsın diye — her seferinde yeniden yüklenmez).
    var chatCache: [UUID: [Message]] = [:]

    /// Karakter başına CANLI arkadaşlık seviyesi/ilerlemesi — ChatViewModel her
    /// güncellemede (mesaj sonrası) buraya yazar. @Observable olduğu için
    /// CharacterProfileView bunu doğrudan okuyup ANINDA güncellenir (LocalConversation
    /// Store'un arka plan kaydını beklemeden). Anahtar yoksa profil kalıcı depoya düşer.
    var levelCache: [UUID: (level: Int, progress: Double)] = [:]

    func setLevel(_ id: UUID, level: Int, progress: Double) {
        levelCache[id] = (level, progress)
        // KALICI olarak da yaz: bu ve levelCache bellek-içi, uygulama yeniden
        // açılınca boş başlıyor ve seviye sunucu hidrasyonuna kadar yanlış
        // görünüyordu (bkz. RelationshipLevelStore).
        RelationshipLevelStore.set(id, level: level, progress: progress)
    }

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

    /// ISO8601 çözücüleri — mesaj başına yeni formatter ALLOKE ETME (pahalı).
    /// Bir kez kurulur, hydrateConversations tüm mesajlar için bunları kullanır.
    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso8601Plain = ISO8601DateFormatter()

    func setTyping(_ id: UUID, _ value: Bool) {
        if value { typingCharacterIDs.insert(id) } else { typingCharacterIDs.remove(id) }
    }

    var currentCharacter: Character? {
        if let id = currentCharacterID, let c = characters.first(where: { $0.id == id }) {
            return c
        }
        return characters.first
    }

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
                // Review Mode anahtarını da içerir: açıksa `characters_review`
                // tablosundan çeker (bkz. ReviewModeService).
                fetched = try await ReviewModeService.shared.fetchCharacters()
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

        // Feed'de anında görünmesi gereken görselleri (kart foto + avatar)
        // splash'te önceden indir. Galeri fotoğrafları splash'te YÜKLENMEZ —
        // sadece profil açıldığında talep üzerine gelir (bkz. talep: "görünmeyen
        // fotolar bile RAM tutuyor"). Tümünü önden yüklemek RAM'i şişiriyordu.
        let urls = characters.flatMap { [$0.photoURL, $0.avatarURL].compactMap { $0 } }
        await ImageCache.shared.prefetch(Array(Set(urls)))

        // "Sıfır yerel": sohbet durumunu SUNUCUDAN bellek-içi önbelleğe doldur
        // (bkz. hydrateConversations / LocalConversationStore). Diğer ekranlar
        // (Keşfet "zaten konuşuyor" filtresi, Beğeniler, bildirim gating) bu
        // önbelleği okur — açılışta boş kalmasın diye burada tazelenir.
        // NOT: eski toplu rutin ön-üretimi (ScheduleGenerator.prewarmAll)
        // KALDIRILDI — rutin artık yalnızca disk'te değil bellekte tutulduğu
        // için her açılışta yeniden üretmek pahalı olurdu; rutin artık sohbet
        // AÇILDIĞINDA talep üzerine üretilir (bkz. ChatViewModel.ensureScheduleGenerated).
        //
        // NOT (kritik sıra): `isLoaded` BURADAN ÖNCE true olursa (eski davranış),
        // PlummApp Splash'ten MainTabView'e geçer ve MainTabView.openPendingOnboardingChat
        // `LocalConversationStore.shared.load(for:) == nil` kontrolünü hydrateConversations
        // bitmeden çalıştırabilir — GERÇEK geçmişi olan bir karakter "yeni" sanılıp
        // üstüne taze bir "ilk selam" enjekte ediliyor, tüm önceki mesajlar
        // GİZLENİYORDU (bkz. QA notu 2026-08-26 — Scarlett karakterinde canlı
        // gözlemlendi: 36 kalp / gerçek geçmiş varken sohbet boş açıldı).
        // `isLoaded` artık hydrateConversations bitene KADAR true olmuyor.
        await hydrateConversations()

        isLoaded = true

        // İlk yükleme boru hattı TAMAMEN bitti → artık öne-geliş refresh'i
        // güvenle çalışabilir (bkz. refreshCharacters guard'ı).
        didFinishInitialLoad = true
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
        let (rawStates, msgs) = await (statesT, msgsT)

        var byConv: [UUID: [LastMessage]] = [:]
        for m in msgs { byConv[m.conversationID, default: []].append(m) }

        func parseDate(_ s: String?) -> Date? {
            guard let s else { return nil }
            // Önbelleğe alınmış formatter'lar (bkz. static let yukarıda) —
            // mesaj başına yeniden alloke edilmez.
            return Self.iso8601WithFractional.date(from: s) ?? Self.iso8601Plain.date(from: s)
        }

        // Aynı (user, character) için BİRDEN FAZLA conversation satırı olabilir
        // (bkz. chat/index.ts "dupe'lar" yorumu — sunucu tarafında ARA SIRA hâlâ
        // oluşuyor, kök nedeni ayrı bir konu). `rawStates` `updated_at.desc`
        // sıralı geldiği için buradaki dedup İLK GÖRÜLENİ (= en güncel) tutar,
        // sonrakileri atlar. Bu koruma OLMADAN aşağıdaki döngü her eşleşen
        // characterID'yi SIRAYLA ÜZERİNE yazıyordu — en son işlenen (= en ESKİ
        // dupe, çünkü desc sıralı) kazanıyordu. Canlı bulgu (2026-08-26): bir
        // karakter için 4 dupe conversation vardı, kullanıcı sohbete her
        // girişte AYLAR öncesinin kısa geçmişini görüyordu — yeni mesajlar
        // sunucuda duruyordu ama yerel önbellek yanlış satırdan besleniyordu.
        var seenCharacterIDs = Set<UUID>()
        let states = rawStates.filter { seenCharacterIDs.insert($0.characterID).inserted }

        for state in states {
            // desc → asc (görüntüleme/sayım sırası)
            let convMsgs = Array((byConv[state.id] ?? []).reversed())
            // image_request/voice_request: içsel defter tutma satırı, kendi
            // balonu olarak gösterilmez (bkz. ChatListView.load aynı filtre).
            let messages: [Message] = convMsgs
                .filter { $0.kind != "image_request" && $0.kind != "voice_request" }
                .map {
                    Message.fromServer(role: $0.role, content: $0.content, kind: $0.kind, createdAt: $0.date ?? Date())
                }
            let existing = LocalConversationStore.shared.load(for: state.characterID)
            let stored = LocalConversationStore.Stored(
                messages: messages,
                // Sunucu xp'yi henüz saklamıyor → mevcut yerel xp'yi KORU
                // (komşu alanlar gibi). Eskiden 0'a sıfırlanıyordu → her
                // açılış/öne gelişte xp siliniyordu.
                xp: existing?.xp ?? 0,
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
        guard didFinishInitialLoad else { return } // avoid racing the initial load()
        if let fetched = try? await ReviewModeService.shared.fetchCharacters(), !fetched.isEmpty {
            // id'ye göre BİRLEŞTİR — sunucu cevabında henüz olmayan ama yerelde
            // yeni eklenmiş (ör. az önce yaratılmış) karakterleri KORU. Eskiden
            // tam değiştirme (`characters = fetched`) bunları her öne gelişte
            // düşürüyordu (bkz. CreateCharacterView.createCharacter).
            let fetchedIDs = Set(fetched.map { $0.id })
            let localOnly = characters.filter { !fetchedIDs.contains($0.id) }
            characters = fetched + localOnly
            saveCachedCharacters(characters)
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
