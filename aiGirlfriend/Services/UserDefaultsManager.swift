//
//  UserDefaultsManager.swift
//  Oturum bilgisini saklar (Bible'daki UserDefaultsManager mantığına benzer).
//

import Foundation

final class UserDefaultsManager {
    static let shared = UserDefaultsManager()
    private init() {}

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let userId = "auth.userId"
        static let accessToken = "auth.accessToken"
        static let refreshToken = "auth.refreshToken"
        static let hasSeenSwipeTutorial = "feed.hasSeenSwipeTutorial"
    }

    var userId: String? {
        get { defaults.string(forKey: Keys.userId) }
        set { defaults.set(newValue, forKey: Keys.userId) }
    }

    var accessToken: String? {
        get { defaults.string(forKey: Keys.accessToken) }
        set { defaults.set(newValue, forKey: Keys.accessToken) }
    }

    var refreshToken: String? {
        get { defaults.string(forKey: Keys.refreshToken) }
        set { defaults.set(newValue, forKey: Keys.refreshToken) }
    }

    var hasSeenSwipeTutorial: Bool {
        get { defaults.bool(forKey: Keys.hasSeenSwipeTutorial) }
        set { defaults.set(newValue, forKey: Keys.hasSeenSwipeTutorial) }
    }
}
