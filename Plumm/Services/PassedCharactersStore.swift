//
//  PassedCharactersStore.swift
//  Discover'da sola kaydırılan ("nope") karakterler — sadece cihazda saklanır.
//  BlockedCharactersStore'dan BİLEREK ayrı: bir "nope" kaydırması sadece
//  Discover'daki kartı gizlemeli, `BlockedCharactersStore.isBlocked` gibi
//  bildirimleri (jealousy/bedtime/ghosted) veya Beğeniler listesini
//  ETKİLEMEMELİ — o daha güçlü, kullanıcının chat menüsünden bilerek
//  seçtiği bir "Block" eylemi için.
//

import Foundation

enum PassedCharactersStore {
    private static let key = "feed.passedCharacters"
    private static var map: [String: Bool] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func isPassed(_ characterID: UUID) -> Bool {
        map[characterID.uuidString] ?? false
    }

    static func pass(_ characterID: UUID) {
        var m = map
        m[characterID.uuidString] = true
        map = m
    }
}
