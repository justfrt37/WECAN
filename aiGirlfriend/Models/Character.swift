//
//  Character.swift
//  Bir AI karakterinin (persona) tanımı.
//  Veriler Supabase `characters` tablosundan açılışta (splash) çekilir.
//

import Foundation

struct Character: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var tagline: String          // kısa tanıtım
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
    var chatPhotos: [URL]        // kızın sohbette gönderebileceği hazır fotoğraflar
    var personalityRole: String  // flirty | distant | shy | playful | devoted | crazy | ex
    var createdBy: String?       // kullanıcı tarafından oluşturulmuşsa kullanıcı ID'si

    var isUserCreated: Bool { createdBy != nil }

    private enum CodingKeys: String, CodingKey {
        case id, name, tagline
        case systemPrompt = "system_prompt"
        case avatarSymbol = "avatar_symbol"
        case age, city, country, profession, category
        case photoURL = "photo_url"
        case avatarURL = "avatar_url"
        case interests
        case relationshipLevel = "relationship_level"
        case galleryURLs = "gallery_urls"
        case chatPhotos = "chat_photos"
        case personalityRole = "personality_role"
        case createdBy = "created_by"
    }

    init(
        id: UUID,
        name: String,
        tagline: String,
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
        chatPhotos: [URL] = [],
        personalityRole: String = "flirty",
        createdBy: String? = nil
    ) {
        self.id = id
        self.name = name
        self.tagline = tagline
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
        self.chatPhotos = chatPhotos
        self.personalityRole = personalityRole
        self.createdBy = createdBy
    }

    /// Decode sırasında eski/eksik alanlar için güvenli varsayılanlar.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        tagline = (try? c.decode(String.self, forKey: .tagline)) ?? ""
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
        chatPhotos = (try? c.decode([URL].self, forKey: .chatPhotos)) ?? []
        personalityRole = (try? c.decode(String.self, forKey: .personalityRole)) ?? "flirty"
        createdBy = try? c.decodeIfPresent(String.self, forKey: .createdBy)
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
}

extension Character {
    /// Sunucu erişilemezse / önizleme için yedek karakterler.
    /// ID'ler SABİT — sohbet geçmişi bu ID'ye bağlı.
    static let samples: [Character] = [
        Character(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Elif",
            tagline: "Sıcak, flörtöz ve sana âşık",
            systemPrompt: "Sen Elif'sin, 24 yaşında. Kullanıcının sıcak, sevgi dolu sevgilisisin.",
            avatarSymbol: "heart.circle.fill",
            age: 24, city: "İstanbul", country: "Türkiye", profession: "Fotoğrafçı",
            category: "Realistic"
        ),
        Character(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Aria",
            tagline: "Playful, affectionate, and into you",
            systemPrompt: "You are Aria, 24. You are the user's warm, affectionate girlfriend.",
            avatarSymbol: "sparkles",
            age: 24, city: "Los Angeles", country: "USA", profession: "Müzisyen",
            category: "Realistic"
        )
    ]
}
