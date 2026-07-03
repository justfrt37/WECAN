//
//  IcebreakerPool.swift
//  Keşfet'te "tanışmak ister misin?" onayından sonra sohbet kutusuna önceden
//  yazılan açılış mesajları — kullanıcı başına sırayla döner, art arda aynı
//  mesaj iki farklı karaktere gitmez.
//

import Foundation

enum IcebreakerPool {
    private static let messages: [String] = [
        String(localized: "Hey! How are you? 😊"),
        String(localized: "Hi, nice to meet you 👋"),
        String(localized: "Hey! How's your day going?"),
        String(localized: "Hi, want to chat a bit? 💬"),
        String(localized: "Hey! Finally found you 😄"),
        String(localized: "Hey, what are you up to right now?"),
        String(localized: "Hey! I liked your profile, let's talk 🙂"),
        String(localized: "Hi, guess I get to send the first message 😅"),
        String(localized: "Hey! How was your day?"),
        String(localized: "Hi, shall we start chatting? ✨"),
        String(localized: "Hello! I'd love to talk to you."),
        String(localized: "Hey, what's up? Nice to meet you 👋")
    ]

    private static let key = "feed.icebreakerIndex"

    /// Sıradaki açılış mesajını döner ve döngüyü ilerletir.
    static func next() -> String {
        let idx = UserDefaults.standard.integer(forKey: key) % messages.count
        UserDefaults.standard.set((idx + 1) % messages.count, forKey: key)
        return messages[idx]
    }
}
