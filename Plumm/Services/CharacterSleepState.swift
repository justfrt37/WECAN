//
//  CharacterSleepState.swift
//  Tek doğru kaynak: bir karakter şu an GERÇEKTEN uyuyor mu.
//
//  As of 2026-08-31 (user request): the daily SCHEDULE no longer gates this
//  at all — a character's routine is flavor/tone only (bkz. ChatViewModel.
//  currentActivity, chat/index.ts CURRENT ACTIVITY block), never something
//  that makes her unavailable. "Asleep" now means ONLY that she agreed to go
//  to sleep in conversation (chat/index.ts classifySleepAgreement →
//  manualSleepAt) and hasn't been woken since — no nightly schedule-driven
//  cycle, no session-window logic. Previously this also considered the
//  schedule's sleep block; that check (and its session-bound override
//  window) was removed here.
//

import Foundation

enum CharacterSleepState {
    static func isEffectivelyAsleep(stored: LocalConversationStore.Stored?, now: Date = Date()) -> Bool {
        guard let stored, let manualSleepAt = stored.manualSleepAt else { return false }
        if let wokenUpAt = stored.wokenUpAt, wokenUpAt >= manualSleepAt { return false }
        return true
    }
}
