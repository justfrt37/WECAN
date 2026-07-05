//
//  SleepyContent.swift
//  Idle-timeout "can we sleep?" / goodnight lines AND the daily real-bedtime
//  announcement (same goodbye text, reused — see NotificationScheduler
//  .rescheduleBedtime). Single line per stage, no role/vibe axis (matches
//  the exact phrasing requested — see docs/superpowers/specs/2026-07-05-
//  sleep-state-redesign-design.md). Follows RoleOnlyContent.swift's
//  ConversationLanguage (tr/en) pattern, NOT the Localizable.xcstrings UI
//  catalog — this is bot dialogue, not a UI string.
//

import Foundation

enum SleepyContent {
    private static let byLanguage: [String: (question: String, goodbye: String)] = [
        "en": (
            question: String(localized: "I want to sleep, if that's ok can we sleep?"),
            goodbye: String(localized: "I am sleeping, goodnight")
        ),
        "tr": (
            question: "Uyumak istiyorum, uygunsa uyuyabilir miyiz?",
            goodbye: "Uyuyorum, iyi geceler"
        ),
    ]

    static func question(language: String) -> String {
        (byLanguage[language] ?? byLanguage["en"]!).question
    }

    static func goodbye(language: String) -> String {
        (byLanguage[language] ?? byLanguage["en"]!).goodbye
    }
}
