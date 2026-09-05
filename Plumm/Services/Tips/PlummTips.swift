//
//  PlummTips.swift
//  First-run feature hints (Apple TipKit). Each tip is anchored to a real
//  control and shows once. Display frequency is throttled to one tip per day
//  (see configureIfEligible) so a new user is introduced to features gradually
//  over their first week instead of all at once.
//
//  Configured ONLY after onboarding completes and never in review mode, so no
//  tip can fire during the onboarding flow or an App Review walkthrough.
//  (bkz. PlummApp — configureIfEligible çağrısı.)
//

import TipKit

enum PlummTips {
    private static var configured = false

    /// Safe to call repeatedly / from multiple entry points — configures once.
    static func configureIfEligible(onboardingCompleted: Bool) {
        guard !configured,
              onboardingCompleted,
              !ReviewModeService.isEnabledSnapshot
        else { return }
        configured = true
        try? Tips.configure([
            .displayFrequency(.daily),
            .datastoreLocation(.applicationDefault),
        ])
    }

    /// Dev only — "Reset feature tips" row in Settings.
    static func reset() {
        try? Tips.resetDatastore()
    }
}

private let showOnce: [any TipOption] = [Tips.MaxDisplayCount(1)]

struct SendFirstMessageTip: Tip {
    var title: Text { Text("Say hi") }
    var message: Text? {
        Text("Type below to start the conversation.")
    }
    var options: [any TipOption] { showOnce }
}

struct RequestPhotoTip: Tip {
    var title: Text { Text("Ask for a photo") }
    var message: Text? {
        Text("Tap “Send me a photo” to ask for a picture.")
    }
    var options: [any TipOption] { showOnce }
}

struct VoiceMessageTip: Tip {
    var title: Text { Text("Send a voice message") }
    var message: Text? {
        Text("She can reply in her own voice.")
    }
    var options: [any TipOption] { showOnce }
}

struct VoiceCallTip: Tip {
    var title: Text { Text("Call her") }
    var message: Text? {
        Text("Start a live voice call.")
    }
    var options: [any TipOption] { showOnce }
}

struct TokenBadgeTip: Tip {
    var title: Text { Text("These are your tokens") }
    var message: Text? {
        Text("Messages, photos, calls and boosts spend them. Tap to see every price and top up.")
    }
    var options: [any TipOption] { showOnce }
}

struct LevelSectionTip: Tip {
    var title: Text { Text("Your closeness level") }
    var message: Text? {
        Text("It grows as you chat. You can also spend tokens to jump ahead.")
    }
    var options: [any TipOption] { showOnce }
}

struct CreateCharacterTip: Tip {
    var title: Text { Text("Make your own") }
    var message: Text? {
        Text("Design a character from scratch.")
    }
    var options: [any TipOption] { showOnce }
}
