//
//  ReviewModeService.swift
//  Review Mode — App Store inceleme (Apple review) sürecinde uygulamanın daha
//  "güvenli" bir karakter seti göstermesi için UZAKTAN (backend) açılıp kapanan
//  anahtar. Tüm review-mode mantığı yalnızca bu dosyada toplanır; başka yerlere
//  sızmaz (CharacterStore sadece `fetchCharacters()`'ı çağırır).
//
//  ── Backend sözleşmesi ─────────────────────────────────────────────────────
//  1) Anahtar `app_config` adlı bir tabloda tutulur (public read RLS gerekli).
//     Anahtar adı bilerek belirsiz/gizli seçildi: "kokomombo" (review_mode değil).
//        create table app_config (
//          key        text primary key,
//          bool_value boolean not null default false
//        );
//        insert into app_config (key, bool_value) values ('kokomombo', false);
//     REST okuma:
//        GET /rest/v1/app_config?select=bool_value&key=eq.kokomombo
//        → [{ "bool_value": true }]
//
//  2) Anahtar TRUE geldiğinde karakterler normal `characters` tablosu yerine
//     `characters_review` tablosundan çekilir (AYNI şema, "güvenli" kızlar).
//     FALSE veya belirlenemiyorsa → normal `characters`.
//
//  Apple incelemeye başlarken backend'de `kokomombo`'yu true yap; onaylanınca
//  false'a çek. İstemci tarafında hiçbir sürüm/güncelleme gerekmez.
//  ───────────────────────────────────────────────────────────────────────────
//

import Foundation

@MainActor
final class ReviewModeService {
    static let shared = ReviewModeService()

    /// Karakterlerin çekileceği tablolar.
    static let normalTable = "characters"
    static let reviewTable = "characters_review"

    /// Son bilinen anahtar değeri (kalıcı, UserDefaults). Ağ cevabı gelene kadar
    /// bununla karar veririz — böylece açılıştaki disk-önbellek gösterimi (bkz.
    /// CharacterStore.load) doğru modla tutarlı olur.
    private(set) var isEnabled: Bool
    nonisolated private static let cacheKey = "review_mode.enabled.v1"

    private let characterService = CharacterService()

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.cacheKey)
    }

    /// Review mode'a göre o an aktif tablo adı.
    var activeTable: String { isEnabled ? Self.reviewTable : Self.normalTable }

    // MARK: - Sohbet promptu (review modda flörtsüz)

    /// Ağ/aktör beklemeden okunabilen anlık flag (kalıcı UserDefaults). ChatService
    /// gibi MainActor olmayan yerlerden senkron kullanılır.
    nonisolated static var isEnabledSnapshot: Bool {
        UserDefaults.standard.bool(forKey: cacheKey)
    }

    /// Review mode AÇIKKEN sohbette gönderilecek system prompt: arkadaş-canlısı,
    /// tamamen flörtsüz/platonik. KAPALIYKEN karakterin kendi promptu.
    /// (Backend `chat` fonksiyonu ayrıca `reviewMode` bayrağıyla flört direktifini
    /// atlar — çift güvence; bkz. supabase/functions/chat/index.ts.)
    nonisolated static func systemPrompt(for character: Character) -> String {
        guard isEnabledSnapshot else { return character.systemPrompt }
        return """
        You are \(character.name), a warm and friendly companion. Talk to the user like a \
        kind, caring friend. Keep everything wholesome and strictly platonic. Do NOT flirt, \
        do NOT be romantic, seductive, suggestive or sexual in any way, and never steer the \
        conversation toward dating or romance. Chat naturally about everyday topics — hobbies, \
        feelings, daily life. Always reply in the user's language.
        """
    }

    /// Anahtarı backend'den tazeler + kalıcı önbelleğe yazar. Ağ hatasında son
    /// bilinen değeri sessizce korur. Döndürdüğü değer güncel `isEnabled`.
    @discardableResult
    func refreshFlag() async -> Bool {
        if let value = await fetchFlag() {
            isEnabled = value
            UserDefaults.standard.set(value, forKey: Self.cacheKey)
        }
        return isEnabled
    }

    /// Anahtarı tazeler VE doğru tablodan karakterleri çeker.
    /// CharacterStore, `CharacterService.fetchAll()` yerine bunu çağırır.
    func fetchCharacters() async throws -> [Character] {
        await refreshFlag()
        return try await characterService.fetchAll(table: activeTable)
    }

    // MARK: - Ağ

    private func fetchFlag() async -> Bool? {
        let endpoint = "\(Config.supabaseURL)/rest/v1/app_config?select=bool_value&key=eq.kokomombo"
        guard let url = URL(string: endpoint) else { return nil }

        let request = SupabaseRequest.authorized(url: url, bearer: SupabaseRequest.sessionBearer, timeout: 8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let rows = try JSONDecoder().decode([FlagRow].self, from: data)
            return rows.first?.boolValue
        } catch {
            return nil
        }
    }

    private struct FlagRow: Decodable {
        let boolValue: Bool
        enum CodingKeys: String, CodingKey { case boolValue = "bool_value" }
    }
}
