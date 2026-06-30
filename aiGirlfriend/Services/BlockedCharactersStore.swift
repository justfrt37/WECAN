//
//  BlockedCharactersStore.swift
//  Kullanıcının engellediği karakterler — yalnızca cihazda saklanır,
//  sunucuya/diğer cihazlara senkronize edilmez.
//

import Foundation

enum BlockedCharactersStore {
    private static let key = "chat.blockedCharacters"
    private static var map: [String: Bool] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func isBlocked(_ characterID: UUID) -> Bool {
        map[characterID.uuidString] ?? false
    }

    static func block(_ characterID: UUID) {
        var m = map
        m[characterID.uuidString] = true
        map = m
    }
}
