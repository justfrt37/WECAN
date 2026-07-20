//
//  ChatMaintenance.swift
//  "Sohbeti Temizle" — hem ChatView'in gear menüsünden hem de Sohbetler
//  listesindeki uzun-basma menüsünden çağrılabilen paylaşılan temizleme adımı.
//

import Foundation

enum ChatMaintenance {
    /// Hem sunucudaki (conversation/messages) hem cihazdaki kaydı siler — aksi
    /// halde bir sonraki açılışta sunucudan eski geçmiş geri gelir (silinmiş gibi
    /// görünüp sonra "yeniden gönderilmiş" gibi geri dönerdi).
    @MainActor
    static func clearChat(character: Character, store: CharacterStore) async {
        store.chatCache[character.id] = []
        LocalConversationStore.shared.clear(for: character.id)
        ReadTracker.setSeen(character.id, 0)
        try? await ChatService().clearConversation(character: character)
    }

}
