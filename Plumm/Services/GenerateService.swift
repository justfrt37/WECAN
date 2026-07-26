//
//  GenerateService.swift
//  Sunucudaki "generate" Edge Function'ı çağırır (xAI Grok).
//  Karakter yaratmada "AI ile senaryo öner" için kullanılır.
//

import Foundation

struct GenerateService {
    private struct Request: Encodable { let prompt: String; let maxTokens: Int }
    private struct Response: Decodable { let text: String? }

    func generate(prompt: String, maxTokens: Int = 220) async -> String? {
        guard let url = URL(string: "\(Config.supabaseURL)/functions/v1/generate") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bearer = UserDefaultsManager.shared.accessToken ?? Config.supabaseAnonKey
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.httpBody = try? JSONEncoder().encode(Request(prompt: prompt, maxTokens: maxTokens))

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let text = decoded.text, !text.isEmpty
        else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
