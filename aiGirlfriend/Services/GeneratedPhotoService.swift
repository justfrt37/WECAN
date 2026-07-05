//
//  GeneratedPhotoService.swift
//  Kullanıcının bir karakterle sohbette ürettiği ÖZEL fotoğrafları çeker.
//  `generated_photos` tablosu RLS ile auth.uid()'e göre filtrelenir — bu
//  yüzden anon key ile çağrılırsa boş döner, gerçek kullanıcı JWT'si gerekir.
//

import Foundation

struct GeneratedPhotoService {
    func fetch(characterId: UUID) async throws -> [URL] {
        guard let accessToken = UserDefaultsManager.shared.accessToken else { return [] }

        let endpoint = "\(Config.supabaseURL)/rest/v1/generated_photos" +
            "?select=url,created_at&character_id=eq.\(characterId.uuidString.lowercased())" +
            "&order=created_at.desc"
        guard let url = URL(string: endpoint) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "GeneratedPhotoService", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't fetch generated photos (HTTP \(code))"])
        }
        struct Row: Decodable { let url: String }
        let rows = try JSONDecoder().decode([Row].self, from: data)
        return rows.compactMap { URL(string: $0.url) }
    }
}
