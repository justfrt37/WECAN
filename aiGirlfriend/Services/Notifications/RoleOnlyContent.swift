//
//  RoleOnlyContent.swift
//  Notification dialogue that varies only by personality role — no vibe/tier axis.
//

import Foundation

enum LikedYouContent {
    /// First message a bot sends when the user opens a "someone liked you" notification
    /// for a bot they've never talked to. Tone: she noticed the user first, wants to meet.
    private static let byLanguageRole: [String: [String: String]] = [
        "en": [
            "flirty":  String(localized: "I saw your profile and just had to say hi 😘 I'm glad I found you."),
            "distant": String(localized: "I don't usually do this. But I liked what I saw. Hey."),
            "shy":     String(localized: "Um, hi... I saw you and got a little nervous, but I wanted to say hello."),
            "playful": String(localized: "Ooh, I spotted you first! 😄 Couldn't resist saying hi."),
            "devoted": String(localized: "I have a feeling about you. I'm really glad you're here — hi."),
            "crazy":   String(localized: "I saw you and I just KNEW. Hi, I've been waiting for someone like you 💥"),
            "ex":      String(localized: "Didn't think I'd reach out first. But here we are. Hi.")
        ],
        "tr": [
            "flirty":  "Profilini gördüm ve merhaba demeden duramadım 😘 seni bulduğuma sevindim.",
            "distant": "Genelde bunu yapmam. Ama gördüğüm şeyi beğendim. Selam.",
            "shy":     "Şey, merhaba... seni gördüm ve biraz gerildim, ama merhaba demek istedim.",
            "playful": "Oo, seni ilk ben fark ettim! 😄 Merhaba demeden duramadım.",
            "devoted": "Sana dair bir hissim var. Burada olduğuna gerçekten sevindim — merhaba.",
            "crazy":   "Seni gördüm ve içimden bir ses BİLDİM dedi. Merhaba, senin gibi birini bekliyordum 💥",
            "ex":      "İlk ben yazarım sanmazdım. Ama işte buradayız. Selam."
        ]
    ]

    static func opener(language: String, forRole role: String) -> String {
        let resolvedLanguage = byLanguageRole[language] != nil ? language : "en"
        let byRole = byLanguageRole[resolvedLanguage]!
        return byRole[role] ?? byRole["flirty"]!
    }
}
