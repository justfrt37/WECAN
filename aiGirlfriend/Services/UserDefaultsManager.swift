//
//  UserDefaultsManager.swift
//  Oturum bilgisini saklar (Bible'daki UserDefaultsManager mantığına benzer).
//

import Foundation
import Security

final class UserDefaultsManager {
    static let shared = UserDefaultsManager()
    private init() {}

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let userId = "auth.userId"
        static let accessToken = "auth.accessToken"
        static let refreshToken = "auth.refreshToken"
        static let hasSeenSwipeTutorial = "feed.hasSeenSwipeTutorial"
        static let skipMeetConfirm = "feed.skipMeetConfirm"
    }

    // userId/accessToken/refreshToken used to live in UserDefaults, which is
    // wiped on every uninstall/reinstall (and differs across separately-signed
    // app variants used for testing). That silently orphaned the whole
    // anonymous identity — and every character/chat created under it, via RLS
    // — the moment the app was reinstalled: a fresh launch found no
    // refresh_token and minted a brand-new Supabase anon user (see
    // AuthService/SupabaseAuth.recover for the retry hardening on the other
    // half of this same failure mode). Keychain survives reinstalls of the
    // same app on the same device, so the identity now does too.

    var userId: String? {
        get { migratedRead(Keys.userId) }
        set { Keychain.write(Keys.userId, newValue) }
    }

    var accessToken: String? {
        get { migratedRead(Keys.accessToken) }
        set { Keychain.write(Keys.accessToken, newValue) }
    }

    var refreshToken: String? {
        get { migratedRead(Keys.refreshToken) }
        set { Keychain.write(Keys.refreshToken, newValue) }
    }

    /// Keychain first; if empty, this install predates the Keychain switch —
    /// fall back to the old UserDefaults value ONCE, copy it into Keychain,
    /// and wipe the UserDefaults copy. Without this, flipping storage
    /// backends would itself orphan every already-installed user's identity
    /// on their next launch — exactly the bug this change exists to prevent.
    private func migratedRead(_ key: String) -> String? {
        if let value = Keychain.read(key) { return value }
        guard let legacy = defaults.string(forKey: key) else { return nil }
        Keychain.write(key, legacy)
        defaults.removeObject(forKey: key)
        return legacy
    }

    var hasSeenSwipeTutorial: Bool {
        get { defaults.bool(forKey: Keys.hasSeenSwipeTutorial) }
        set { defaults.set(newValue, forKey: Keys.hasSeenSwipeTutorial) }
    }

    /// Kullanıcı "bir daha gösterme" kutucuğunu işaretlediyse, Keşfet'te beğenince
    /// artık "tanışmak ister misin?" onayı sorulmaz.
    var skipMeetConfirm: Bool {
        get { defaults.bool(forKey: Keys.skipMeetConfirm) }
        set { defaults.set(newValue, forKey: Keys.skipMeetConfirm) }
    }
}

/// Minimal generic-password Keychain wrapper — one item per string key.
private enum Keychain {
    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        guard let value, let data = value.data(using: .utf8) else {
            SecItemDelete(query as CFDictionary)
            return
        }
        var attributes = query
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }
}
