//
//  CharacterStore.swift
//  Açılışta çekilen karakterleri uygulama boyunca tutar.
//

import Foundation
import Observation

@MainActor
@Observable
final class CharacterStore {
    var characters: [Character] = []
    var isLoaded = false
    var errorMessage: String?

    /// Feed'de o an görünen karakter (Chat sekmesi bunu kullanır).
    var currentCharacterID: UUID?

    /// O an cevap bekleyen ("yazıyor") karakterler — Chat History bunu gösterir.
    var typingCharacterIDs: Set<UUID> = []

    /// Karakter başına sohbet geçmişi önbelleği (Chat History'de doldurulur,
    /// ChatView anında açılsın diye — her seferinde yeniden yüklenmez).
    var chatCache: [UUID: [Message]] = [:]

    func setTyping(_ id: UUID, _ value: Bool) {
        if value { typingCharacterIDs.insert(id) } else { typingCharacterIDs.remove(id) }
    }

    var currentCharacter: Character? {
        if let id = currentCharacterID, let c = characters.first(where: { $0.id == id }) {
            return c
        }
        return characters.first
    }

    private let service = CharacterService()

    /// Splash'te çağrılır. Hata olursa yedek (samples) ile devam eder ki
    /// uygulama boş ekranda takılmasın.
    func load() async {
        errorMessage = nil
        do {
            let fetched = try await service.fetchAll()
            characters = fetched.isEmpty ? Character.samples : fetched
        } catch {
            errorMessage = error.localizedDescription
            characters = Character.samples
        }

        // Tüm görselleri splash'te önceden indir ve cache'le; feed'de
        // "yükleniyor" görünmesin.
        var urls = characters.flatMap { [$0.photoURL, $0.avatarURL].compactMap { $0 } }
        urls += characters.flatMap { $0.galleryURLs }
        await ImageCache.shared.prefetch(Array(Set(urls)))

        isLoaded = true
    }
}
