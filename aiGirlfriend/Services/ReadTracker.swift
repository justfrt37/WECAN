//
//  ReadTracker.swift
//  Her karakter için kullanıcının GÖRDÜĞÜ bot (assistant) mesajı sayısını tutar.
//  Okunmamış = sunucudaki bot mesajı sayısı − görülen sayı.
//  (Zaman damgası yerine sayaç → saat kayması/zamanlama sorunlarından etkilenmez.)
//

import Foundation

enum ReadTracker {
    private static let key = "chat.seenCount"
    private static var map: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Kullanıcının bu karakterden gördüğü bot mesajı sayısı.
    static func seen(_ characterID: UUID) -> Int {
        map[characterID.uuidString] ?? 0
    }

    static func setSeen(_ characterID: UUID, _ count: Int) {
        var m = map
        m[characterID.uuidString] = count
        map = m
    }
}
