//
//  GeneratedPhotoService.swift
//  Kullanıcının bir karakterle sohbette ürettiği ÖZEL fotoğrafları çeker.
//  `generated_photos` tablosu kaldırıldı (014_drop_generated_photos.sql) —
//  per-user teslimatlar artık kendi `character_photos` satırı (user_id dolu,
//  katalog satırlarından ayrı). RLS `user_id = auth.uid()` ile filtreler; bu
//  yüzden anon key ile çağrılırsa boş döner, gerçek kullanıcı JWT'si gerekir.
//

import Foundation

struct GeneratedPhotoService {
    func fetch(characterId: UUID) async throws -> [URL] {
        guard UserDefaultsManager.shared.accessToken != nil,
              let userId = UserDefaultsManager.shared.userId else { return [] }

        let endpoint = "\(Config.supabaseURL)/rest/v1/character_photos" +
            "?select=url,created_at&character_id=eq.\(characterId.uuidString.lowercased())" +
            "&user_id=eq.\(userId)" +
            "&order=created_at.desc"
        guard let url = URL(string: endpoint) else { throw URLError(.badURL) }

        return try await fetch(url: url, retrying: true)
    }

    private func fetch(url: URL, retrying: Bool) async throws -> [URL] {
        // Bearer'ı her denemede tazele — recover() sonrası yeni token gelir.
        guard let accessToken = UserDefaultsManager.shared.accessToken else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "GeneratedPhotoService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't fetch generated photos"])
        }
        // Bildirimden saatler sonra token süresi dolabilir — ConversationsService.get
        // ile aynı desen: 401'de bir kez yenile + tekrar dene, böylece özel
        // fotoğraflar token bitince kendini onarır.
        if http.statusCode == 401, retrying {
            _ = await SupabaseAuth.recover()
            return try await fetch(url: url, retrying: false)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "GeneratedPhotoService", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't fetch generated photos (HTTP \(http.statusCode))"])
        }
        struct Row: Decodable { let url: String }
        let rows = try JSONDecoder().decode([Row].self, from: data)
        return rows.compactMap { URL(string: $0.url) }
    }
}
