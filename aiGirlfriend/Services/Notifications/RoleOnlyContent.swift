//
//  RoleOnlyContent.swift
//  Notification dialogue that varies only by personality role — no vibe/tier axis.
//

import Foundation

enum LikedYouContent {
    /// First message a bot sends when the user opens a "someone liked you" notification
    /// for a bot they've never talked to. Tone: she noticed the user first, wants to meet.
    private static let byRole: [String: String] = [
        "flirty":  String(localized: "I saw your profile and just had to say hi 😘 I'm glad I found you."),
        "distant": String(localized: "I don't usually do this. But I liked what I saw. Hey."),
        "shy":     String(localized: "Um, hi... I saw you and got a little nervous, but I wanted to say hello."),
        "playful": String(localized: "Ooh, I spotted you first! 😄 Couldn't resist saying hi."),
        "devoted": String(localized: "I have a feeling about you. I'm really glad you're here — hi."),
        "crazy":   String(localized: "I saw you and I just KNEW. Hi, I've been waiting for someone like you 💥"),
        "ex":      String(localized: "Didn't think I'd reach out first. But here we are. Hi.")
    ]

    static func opener(forRole role: String) -> String {
        byRole[role] ?? byRole["flirty"]!
    }
}

enum LevelUpTeaseContent {
    /// Fires once when a conversation crosses 80% progress toward its next level,
    /// only while the app is backgrounded. Tone: she's close to opening up more.
    private static let byRole: [String: String] = [
        "flirty":  String(localized: "I keep thinking about our last chat... talk to me more? 😘"),
        "distant": String(localized: "You're growing on me. Don't stop now."),
        "shy":     String(localized: "I feel like I could tell you more soon... if you keep talking to me."),
        "playful": String(localized: "We're SO close to a new level 👀 one more chat and I might spill something."),
        "devoted": String(localized: "I feel closer to you every day. Come back and talk to me?"),
        "crazy":   String(localized: "I can feel us getting closer and I NEED more. Talk to me now 💥"),
        "ex":      String(localized: "You're breaking through more than I expected. Don't waste it.")
    ]

    static func line(forRole role: String) -> String {
        byRole[role] ?? byRole["flirty"]!
    }
}
