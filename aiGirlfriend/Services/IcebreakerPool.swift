//
//  IcebreakerPool.swift
//  Keşfet'te "tanışmak ister misin?" onayından sonra sohbet kutusuna önceden
//  yazılan açılış mesajları — kullanıcı başına sırayla döner, art arda aynı
//  mesaj iki farklı karaktere gitmez.
//

import Foundation

enum IcebreakerPool {
    private static let messages: [String] = [
        "Selam! Nasılsın? 😊",
        "Merhaba, seninle tanışmak güzel 👋",
        "Hey! Bugün nasıl geçiyor?",
        "Selam, biraz sohbet edelim mi? 💬",
        "Merhaba! Seni buldum sonunda 😄",
        "Hey, ne yapıyorsun şu an?",
        "Selam! Profilini beğendim, tanışalım 🙂",
        "Merhaba, ilk mesaj bana düştü galiba 😅",
        "Hey! Günün nasıl geçti?",
        "Selam, sohbete başlayalım mı? ✨",
        "Merhaba! Seninle konuşmak isterim.",
        "Hey, naber? Yeni tanışıyoruz 👋"
    ]

    private static let key = "feed.icebreakerIndex"

    /// Sıradaki açılış mesajını döner ve döngüyü ilerletir.
    static func next() -> String {
        let idx = UserDefaults.standard.integer(forKey: key) % messages.count
        UserDefaults.standard.set((idx + 1) % messages.count, forKey: key)
        return messages[idx]
    }
}
