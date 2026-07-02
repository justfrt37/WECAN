//
//  ChatMaintenance.swift
//  "Sohbeti Temizle" — hem ChatView'in gear menüsünden hem de Sohbetler
//  listesindeki uzun-basma menüsünden çağrılabilen paylaşılan temizleme adımı.
//

import Foundation

enum ChatMaintenance {
    @MainActor
    static func clearChat(characterID: UUID, store: CharacterStore) {
        store.chatCache[characterID] = []
        LocalConversationStore.shared.clear(for: characterID)
        ReadTracker.setSeen(characterID, 0)
    }
}
