//
//  LikedByStore.swift
//  "Who liked you" — device-local only, mirrors BlockedCharactersStore's pattern.
//  One random eligible bot gets added per calendar day (see NotificationScheduler
//  .rescheduleLikedYou). Entries persist until the user actually replies to that
//  bot (see LikesView) — not just until the bot's opener line gets injected,
//  so the liker doesn't vanish from Likes before the user notices them.
//

import Foundation

enum LikedByStore {
    private static let likedAtKey = "liked.by.likedAt"           // [String: String] characterID -> ISO date
    private static let lastPickDateKey = "liked.by.lastPickDate" // yyyy-MM-dd of the last daily pick

    private static var likedAt: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: likedAtKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: likedAtKey) }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private static let isoFormatter = ISO8601DateFormatter()

    /// Bugün zaten bir seçim yapıldı mı — günde bir kere seçilsin diye.
    static func hasPickedToday() -> Bool {
        UserDefaults.standard.string(forKey: lastPickDateKey) == dayFormatter.string(from: Date())
    }

    static func likedCharacterIDs() -> Set<UUID> {
        Set(likedAt.keys.compactMap(UUID.init))
    }

    static func likedAt(_ characterID: UUID) -> Date? {
        likedAt[characterID.uuidString].flatMap { isoFormatter.date(from: $0) }
    }

    /// Bugünün rastgele seçimini kaydeder — aynı bot bir daha asla tekrar seçilmesin
    /// diye kalıcı kalır (bkz. NotificationScheduler eligible filtresi).
    static func recordLike(_ characterID: UUID) {
        var m = likedAt
        guard m[characterID.uuidString] == nil else { return }
        m[characterID.uuidString] = isoFormatter.string(from: Date())
        likedAt = m
        UserDefaults.standard.set(dayFormatter.string(from: Date()), forKey: lastPickDateKey)
    }
}
