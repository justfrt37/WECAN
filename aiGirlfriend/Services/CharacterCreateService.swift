//
//  CharacterCreateService.swift
//  Builder seçimlerinden AI ile karakter yaratıp Supabase'e kaydeder.
//

import Foundation

struct CharacterCreateService {

    /// Görünüm seçimlerinden ("hairstyle" vb. sihirbaz adımları) bir karakter
    /// fotoğrafı üretir — hiçbir DB kaydı OLUŞTURMAZ, sadece geçici bir
    /// `photoUrl` döner (sihirbazda ten tonundan sonra, geçmişten önce çağrılır).
    func generateImage(
        hairstyle: String,
        hairColor: String,
        eyeShape: String,
        eyeColor: String,
        noseShape: String,
        skinTone: String,
        bodyType: String = "",
        category: String,
        vibe: String,
        profession: String,
        personalityRole: String,
        ageRange: String,
        ethnicity: String = ""
    ) async -> String? {
        let body: [String: Any] = [
            "generateImageOnly": true,
            "hairstyle": hairstyle,
            "hair_color": hairColor,
            "eye_shape": eyeShape,
            "eye_color": eyeColor,
            "nose_shape": noseShape,
            "skin_tone": skinTone,
            "body_type": bodyType,
            "category": category,
            "vibe": vibe,
            "profession": profession,
            "personality_role": personalityRole,
            "age_range": ageRange,
            "ethnicity": ethnicity,
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
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(GenerateImageResponse.self, from: respData)
        else { return nil }
        return decoded.photoUrl
    }

    private struct GenerateImageResponse: Decodable {
        let photoUrl: String
    }

    /// `create-character`'ın 403 reddi (bkz. create-character/index.ts
    /// checkCreationAllowance) ile bir ağ/decode hatasını ayırt eder —
    /// çağıran taraf (CreateCharacterView) reddedilince ASLA yerel-sadece
    /// bir fallback karakter oluşturmamalı, sunucunun gerçek kararını göstermeli.
    enum CreateOutcome {
        case success(Character, tokenBalance: Int?)
        case rejected(errorCode: String)
        /// PRO ama coin yetmiyor (sunucu 402 + kalan bakiye) → coin paywall.
        case insufficientTokens(tokenBalance: Int)
        case networkFailure
    }

    private struct RejectionBody: Decodable {
        let error: String
    }

    private struct TokenBalanceBody: Decodable {
        let tokenBalance: Int?
    }

    func create(
        name: String,
        photoUrl: String,
        personalityRole: String,
        category: String,
        vibe: String,
        profession: String,
        ageRange: String,
        hairstyle: String,
        hairColor: String,
        eyeShape: String,
        eyeColor: String,
        noseShape: String,
        skinTone: String,
        bodyType: String = "",
        exHistory: String?,
        interests: [String] = [],
        ethnicity: String = ""
    ) async -> CreateOutcome {
        var body: [String: Any] = [
            "name": name,
            "photoUrl": photoUrl,
            "ethnicity": ethnicity,
            "personality_role": personalityRole,
            "category": category,
            "vibe": vibe,
            "profession": profession,
            "age_range": ageRange,
            "personality": personalityRole,
            "hairstyle": hairstyle,
            "hair_color": hairColor,
            "eye_shape": eyeShape,
            "eye_color": eyeColor,
            "nose_shape": noseShape,
            "skin_tone": skinTone,
            "body_type": bodyType,
        ]
        if let history = exHistory, !history.trimmingCharacters(in: .whitespaces).isEmpty {
            body["ex_history"] = history
        }
        if !interests.isEmpty {
            body["interests"] = interests
        }

        guard let url = URL(string: "\(Config.supabaseURL)/functions/v1/create-character"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return .networkFailure }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bearer = UserDefaultsManager.shared.accessToken ?? Config.supabaseAnonKey
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.httpBody = data

        guard let (respData, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse
        else { return .networkFailure }

        if http.statusCode == 403 {
            let code = (try? JSONDecoder().decode(RejectionBody.self, from: respData))?.error ?? "subscription_required"
            return .rejected(errorCode: code)
        }
        if http.statusCode == 402 {
            // PRO ama coin yetmiyor — kalan bakiyeyle birlikte (coin paywall için).
            let bal = (try? JSONDecoder().decode(TokenBalanceBody.self, from: respData))?.tokenBalance ?? 0
            return .insufficientTokens(tokenBalance: bal)
        }
        guard (200..<300).contains(http.statusCode),
              let character = try? JSONDecoder().decode(Character.self, from: respData)
        else { return .networkFailure }
        let bal = (try? JSONDecoder().decode(TokenBalanceBody.self, from: respData))?.tokenBalance
        return .success(character, tokenBalance: bal)
    }
}
