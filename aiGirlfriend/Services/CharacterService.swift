//
//  CharacterService.swift
//  Karakter kataloğunu Supabase REST'ten (anon key) çeker.
//  `characters` tablosu herkese açık okunabilir (RLS: public read).
//

import Foundation

struct CharacterService {
    /// Tüm karakterleri çeker. Sıralama: eklenme tarihine göre.
    func fetchAll() async throws -> [Character] {
        let endpoint = "\(Config.supabaseURL)/rest/v1/characters?select=*&order=id.asc"
        guard let url = URL(string: endpoint) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "CharacterService", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "Karakterler alınamadı (HTTP \(code))"])
        }
        return try JSONDecoder().decode([Character].self, from: data)
    }
}
