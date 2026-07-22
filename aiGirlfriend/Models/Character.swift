//
//  Character.swift
//  Bir AI karakterinin (persona) tanımı.
//  Veriler Supabase `characters` tablosundan açılışta (splash) çekilir.
//

import Foundation

struct Character: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var tagline: String          // kısa tanıtım (kanonik, Türkçe — bkz. localizedTagline)
    var taglineI18n: [String: String]  // dil kodu -> tagline (bkz. supabase/functions/_shared/tagline-i18n.ts)
    var systemPrompt: String     // karakterin persona promptu (sunucuya gönderilir)
    var avatarSymbol: String     // SF Symbol (görsel yoksa yedek)

    // Feed / profil bilgileri (sunucudan gelir; eski kayıtlarda boş olabilir)
    var age: Int?
    var city: String?
    var country: String?
    var profession: String?
    var category: String?        // "Realistic" | "Fantasy" | "Anime" (Tümünü Gör filtreleri)
    var photoURL: URL?           // tam ekran büyük foto
    var avatarURL: URL?          // küçük daire avatar

    // Profil sayfası (her karaktere özel, splash'te çekilir)
    var interests: [String]      // ilgi alanları (emoji + metin)
    var relationshipLevel: Int   // ilişki seviyesi (0 başlar, artar)
    var galleryURLs: [URL]       // profildeki kaydırılabilir resimler
    var personalityRole: String  // flirty | distant | shy | playful | devoted | crazy | ex
    var vibe: String             // Sweet | Mysterious | Energetic | Elegant — builder_selections.vibe
    var createdBy: String?       // kullanıcı tarafından oluşturulmuşsa kullanıcı ID'si
    /// DEV-curated karakterlerde açıkça seçilmiş ElevenLabs sesi (bkz.
    /// dev-create-character) — nil ise voice-message-tts eskisi gibi
    /// role+vibe eşlemesine (elevenVoiceMap.ts) düşer.
    var voiceId: String?

    var isUserCreated: Bool { createdBy != nil }

    private enum CodingKeys: String, CodingKey {
        case id, name, tagline
        case taglineI18n = "tagline_i18n"
        case systemPrompt = "system_prompt"
        case avatarSymbol = "avatar_symbol"
        case age, city, country, profession, category
        case photoURL = "photo_url"
        case avatarURL = "avatar_url"
        case interests
        case relationshipLevel = "relationship_level"
        case galleryURLs = "gallery_urls"
        case personalityRole = "personality_role"
        case createdBy = "created_by"
        case voiceId = "voice_id"
        // Sunucu yanıtında YOK (orada builder_selections.vibe içinde gelir) — sadece
        // kendi disk önbelleğimize (CharacterStore/ChatListView cache) encode/decode
        // ederken kullanılır, aksi halde synthesized Encodable `vibe`'ı sessizce
        // atlar ve bir önbellek round-trip'inden sonra "Sweet"e sıfırlanırdı.
        case vibe
    }

    /// Separate from `CodingKeys` on purpose: `builder_selections` has no matching stored
    /// property (only its nested `vibe` is kept), and adding it to `CodingKeys` breaks
    /// `Encodable` synthesis (no property for the synthesizer to encode it from).
    private enum BuilderSelectionsCodingKey: String, CodingKey {
        case builderSelections = "builder_selections"
    }

    init(
        id: UUID,
        name: String,
        tagline: String,
        taglineI18n: [String: String] = [:],
        systemPrompt: String,
        avatarSymbol: String = "person.crop.circle.fill",
        age: Int? = nil,
        city: String? = nil,
        country: String? = nil,
        profession: String? = nil,
        category: String? = nil,
        photoURL: URL? = nil,
        avatarURL: URL? = nil,
        interests: [String] = [],
        relationshipLevel: Int = 0,
        galleryURLs: [URL] = [],
        personalityRole: String = "flirty",
        vibe: String = "Sweet",
        createdBy: String? = nil,
        voiceId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.taglineI18n = taglineI18n
        self.systemPrompt = systemPrompt
        self.avatarSymbol = avatarSymbol
        self.age = age
        self.city = city
        self.country = country
        self.profession = profession
        self.category = category
        self.photoURL = photoURL
        self.avatarURL = avatarURL
        self.interests = interests
        self.relationshipLevel = relationshipLevel
        self.galleryURLs = galleryURLs
        self.personalityRole = personalityRole
        self.vibe = vibe
        self.createdBy = createdBy
        self.voiceId = voiceId
    }

    /// Decode sırasında eski/eksik alanlar için güvenli varsayılanlar.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        tagline = (try? c.decode(String.self, forKey: .tagline)) ?? ""
        taglineI18n = (try? c.decode([String: String].self, forKey: .taglineI18n)) ?? [:]
        systemPrompt = (try? c.decode(String.self, forKey: .systemPrompt)) ?? ""
        avatarSymbol = (try? c.decode(String.self, forKey: .avatarSymbol)) ?? "person.crop.circle.fill"
        age = try? c.decodeIfPresent(Int.self, forKey: .age)
        city = try? c.decodeIfPresent(String.self, forKey: .city)
        country = try? c.decodeIfPresent(String.self, forKey: .country)
        profession = try? c.decodeIfPresent(String.self, forKey: .profession)
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        photoURL = try? c.decodeIfPresent(URL.self, forKey: .photoURL)
        avatarURL = try? c.decodeIfPresent(URL.self, forKey: .avatarURL)
        interests = (try? c.decode([String].self, forKey: .interests)) ?? []
        relationshipLevel = (try? c.decode(Int.self, forKey: .relationshipLevel)) ?? 0
        galleryURLs = (try? c.decode([URL].self, forKey: .galleryURLs)) ?? []
        personalityRole = (try? c.decode(String.self, forKey: .personalityRole)) ?? "flirty"
        // Önce düz `vibe` anahtarına bak (kendi disk önbelleğimizin formatı) —
        // yoksa sunucunun iç içe `builder_selections.vibe`'ına düş.
        if let topLevelVibe = try? c.decodeIfPresent(String.self, forKey: .vibe) {
            vibe = topLevelVibe
        } else if let bsc = try? decoder.container(keyedBy: BuilderSelectionsCodingKey.self),
           let builderSelections = try? bsc.decodeIfPresent(BuilderSelections.self, forKey: .builderSelections),
           let decodedVibe = builderSelections.vibe {
            vibe = decodedVibe
        } else {
            vibe = "Sweet"
        }
        createdBy = try? c.decodeIfPresent(String.self, forKey: .createdBy)
        voiceId = try? c.decodeIfPresent(String.self, forKey: .voiceId)
    }

    /// `builder_selections` jsonb payload — only `vibe` is needed client-side today.
    private struct BuilderSelections: Decodable {
        let vibe: String?
    }

    /// "Şehir, Ülke" — ikisi de varsa.
    var locationText: String? {
        switch (city, country) {
        case let (c?, k?): return "\(c), \(k)"
        case let (c?, nil): return c
        case let (nil, k?): return k
        default: return nil
        }
    }

    /// "Ad, Yaş" — yaş varsa.
    var nameWithAge: String {
        if let age { return "\(name), \(age)" }
        return name
    }

    /// Cihazın dilinde tagline — taglineI18n'de karşılık yoksa (çeviri
    /// eksik/başarısız, ya da desteklenmeyen bir dil — bkz.
    /// ConversationLanguage.supported) kanonik `tagline`'a düşer.
    var localizedTagline: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return taglineI18n[code] ?? tagline
    }
}

extension Character {
    /// Sunucu erişilemezse / önizleme için yedek karakterler.
    /// ID'ler SABİT — sohbet geçmişi bu ID'ye bağlı.
    static let samples: [Character] = [
        Character(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Elif",
            tagline: "Warm, flirty, and into you",
            systemPrompt: "You are Elif, 24 years old. You are the user's warm, loving girlfriend.",
            avatarSymbol: "heart.circle.fill",
            age: 24, city: "Istanbul", country: "Turkey", profession: "Photographer",
            category: "Realistic"
        ),
        Character(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Aria",
            tagline: "Playful, affectionate, and into you",
            systemPrompt: "You are Aria, 24. You are the user's warm, affectionate girlfriend.",
            avatarSymbol: "sparkles",
            age: 24, city: "Los Angeles", country: "USA", profession: "Musician",
            category: "Realistic"
        )
    ]
}
