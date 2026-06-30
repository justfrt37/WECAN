//
//  CharacterCreateService.swift
//  Builder seçimlerinden AI ile karakter yaratıp Supabase'e kaydeder.
//

import Foundation

struct CharacterCreateService {

    /// Kullanılabilir fotoğraf havuzu (Storage public bucket).
    static let availablePhotos: [(url: String, label: String)] = [
        ("\(Config.supabaseURL)/storage/v1/object/public/characters/created/blonde.png",    "☀️ Blonde"),
        ("\(Config.supabaseURL)/storage/v1/object/public/characters/created/brown.png",     "🤎 Brown"),
        ("\(Config.supabaseURL)/storage/v1/object/public/characters/created/black.png",     "🖤 Dark"),
        ("\(Config.supabaseURL)/storage/v1/object/public/characters/created/red.png",       "🔴 Red"),
        ("\(Config.supabaseURL)/storage/v1/object/public/characters/created/anime_pink.png","🌸 Anime"),
        ("\(Config.supabaseURL)/storage/v1/object/public/characters/created/anime_blue.png","💙 Fantasy"),
    ]

    func create(
        name: String,
        photoUrl: String,
        personalityRole: String,
        category: String,
        vibe: String,
        profession: String,
        ageRange: String,
        exHistory: String?
    ) async -> Character? {
        var body: [String: Any] = [
            "name": name,
            "photoUrl": photoUrl,
            "personality_role": personalityRole,
            "category": category,
            "vibe": vibe,
            "profession": profession,
            "age_range": ageRange,
            "personality": personalityRole,
        ]
        if let history = exHistory, !history.trimmingCharacters(in: .whitespaces).isEmpty {
            body["ex_history"] = history
        }

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
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let character = try? JSONDecoder().decode(Character.self, from: respData)
        else { return nil }
        return character
    }
}
