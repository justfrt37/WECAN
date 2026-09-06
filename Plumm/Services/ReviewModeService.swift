import Foundation

@MainActor
final class ReviewModeService {
    static let shared = ReviewModeService()

    static let normalTable = "characters"
    static let reviewTable = "characters_review"

    private(set) var isEnabled: Bool
    nonisolated private static let cacheKey = "review_mode.enabled.v1"

    private let characterService = CharacterService()

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.cacheKey)
    }

    var activeTable: String { isEnabled ? Self.reviewTable : Self.normalTable }

    nonisolated static var isEnabledSnapshot: Bool {
        UserDefaults.standard.bool(forKey: cacheKey)
    }

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

    @discardableResult
    func refreshFlag() async -> Bool {
        if let value = await fetchFlag() {
            isEnabled = value
            UserDefaults.standard.set(value, forKey: Self.cacheKey)
        }
        return isEnabled
    }

    func fetchCharacters() async throws -> [Character] {
        await refreshFlag()
        return try await characterService.fetchAll(table: activeTable)
    }

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
