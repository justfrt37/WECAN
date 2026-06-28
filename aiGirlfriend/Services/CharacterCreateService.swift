//
//  CharacterCreateService.swift
//  Seçimlerden AI ile karakter yaratıp Supabase'e kaydeder (create-character fn).
//

import Foundation

struct CharacterCreateService {
    /// Higgsfield ile önceden üretilmiş portre havuzu (Storage public).
    private static let poolBase = "\(Config.supabaseURL)/storage/v1/object/public/characters/created"

    /// Saç rengine göre havuzdan görsel + kategori seçer.
    static func pickPhoto(hair: String) -> (url: String, category: String) {
        switch hair {
        case "Siyah":      return ("\(poolBase)/black.png", "Realistic")
        case "Kahverengi": return ("\(poolBase)/brown.png", "Realistic")
        case "Sarışın":    return ("\(poolBase)/blonde.png", "Realistic")
        case "Kızıl":      return ("\(poolBase)/red.png", "Realistic")
        case "Pembe":      return ("\(poolBase)/anime_pink.png", "Anime")
        case "Mavi":       return ("\(poolBase)/anime_blue.png", "Anime")
        default:           return ("\(poolBase)/brown.png", "Realistic")
        }
    }

    func create(gender: String, ethnicity: String, hair: String, eye: String,
                personality: String, interests: [String], relationship: String,
                scenario: String) async -> Character? {
        let (photo, category) = Self.pickPhoto(hair: hair)
        let body: [String: Any] = [
            "gender": gender, "ethnicity": ethnicity, "hair": hair, "eye": eye,
            "personality": personality, "interests": interests,
            "relationship": relationship, "scenario": scenario,
            "photoUrl": photo, "category": category,
        ]
        guard let url = URL(string: "\(Config.supabaseURL)/functions/v1/create-character"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bearer = UserDefaultsManager.shared.accessToken ?? Config.supabaseAnonKey
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.httpBody = data

        guard let (respData, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let character = try? JSONDecoder().decode(Character.self, from: respData)
        else { return nil }
        return character
    }
}
