//
//  FirstHelloContent.swift
//  Boş geçmişte ("ilk kez açılan sohbet") botun gönderdiği ilk mesaj — artık AI
//  ile üretilmiyor (gecikme + tutarsızlık yaratıyordu), sabit 3 varyanttan
//  rastgele biri seçilir. Cihaz diline göre otomatik yerelleşir.
//

import Foundation

enum FirstHelloContent {
    private static let lines: [String] = [
        String(localized: "Hey! I'm so happy you're here 💕"),
        String(localized: "Hi there! I've been waiting to chat with you 😊"),
        String(localized: "Hello! So nice to finally talk to you 👋")
    ]

    static func randomLine() -> String {
        lines.randomElement()!
    }
}
