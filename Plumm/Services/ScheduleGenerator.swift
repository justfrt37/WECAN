//
//  ScheduleGenerator.swift
//  Karakterlerin ilk günlük rutinini üretir — hem tek bir karakter için
//  (ChatViewModel bir sohbet açıldığında), hem de TÜMÜ için toplu olarak
//  (CharacterStore splash'te, kullanıcı hiçbir sohbeti açmadan önce).
//

import Foundation

enum ScheduleGenerator {
    /// Cihazda bu karakter için kayıtlı rutin yoksa üretir ve kaydeder.
    /// Zaten varsa hiçbir şey yapmaz — güvenle tekrar tekrar çağrılabilir.
    static func ensureGenerated(for character: Character, service: ChatService = ChatService()) async {
        guard LocalConversationStore.shared.load(for: character.id)?.schedule == nil else { return }
        guard let schedule = try? await service.generateInitialSchedule(character: character) else { return }
        var stored = LocalConversationStore.shared.load(for: character.id) ?? LocalConversationStore.Stored(
            messages: [], xp: 0, level: max(1, character.relationshipLevel), summary: "", summarizedCount: 0
        )
        stored.schedule = schedule
        LocalConversationStore.shared.save(stored, for: character.id)
    }

    /// Splash'te çağrılır — kullanıcı herhangi bir sohbeti açmadan ÖNCE tüm
    /// karakterlerin rutinini arka planda üretir, böylece ilk kez bir sohbete
    /// girdiğinde "Online" yerine zaten gerçek aktiviteyi görür. Paralel
    /// çalışır (TaskGroup) — sırayla N tane LLM çağrısı beklemek yerine.
    static func prewarmAll(characters: [Character]) async {
        await withTaskGroup(of: Void.self) { group in
            for character in characters {
                group.addTask { await ensureGenerated(for: character) }
            }
        }
    }
}
