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
    /// `keepLevel`/`keepMemories`/`keepBehaviors`: varsayılan false — ChatListView'in
    /// uzun-basma menüsü bunları hiç geçmez (tam sıfırlama, bkz. ChatListView.swift),
    /// ChatView'in dişli menüsü ClearChatOptionsSheet üzerinden geçer.
    @MainActor
    static func clearChat(character: Character, store: CharacterStore, keepLevel: Bool = false, keepMemories: Bool = false, keepBehaviors: Bool = false) async {
        store.chatCache[character.id] = []
        if keepLevel {
            LocalConversationStore.shared.resetKeeping(for: character.id, keepLevel: true)
        } else {
            LocalConversationStore.shared.clear(for: character.id)
        }
        ReadTracker.setSeen(character.id, 0)
        try? await ChatService().clearConversation(character: character, keepLevel: keepLevel, keepMemories: keepMemories, keepBehaviors: keepBehaviors)
    }

}
