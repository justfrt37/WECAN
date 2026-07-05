//
//  CharacterSleepState.swift
//  Tek doğru kaynak: bir karakter şu an GERÇEKTEN uyuyor mu — programa göre
//  mi, yoksa uyandırma/erken-uyuma override'ları mı geçerli. Bkz.
//  LocalConversationStore.Stored.wokenUpAt/manualSleepAt.
//

import Foundation

enum CharacterSleepState {
    static func isEffectivelyAsleep(stored: LocalConversationStore.Stored?, now: Date = Date()) -> Bool {
        guard let stored else { return false } // hiç konuşulmamış — program henüz alakasız
        if stored.wokenUpAt != nil { return false }       // şu an uyandırma override'ı aktif
        if stored.manualSleepAt != nil { return true }    // erken-uyuma override'ı aktif
        guard let schedule = stored.schedule,
              let block = ScheduleLookup.currentBlock(schedule: schedule, date: now) else { return false }
        return block.isSleep
    }
}
