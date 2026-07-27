//
//  LikedByStore.swift
//  "Who liked you" — device-local only, mirrors BlockedCharactersStore's pattern.
//  One random eligible bot gets added every ~15-30 min (see NotificationScheduler
//  .rescheduleLikedYou). Entries persist until the user actually replies to that
//  bot (see LikesView) — not just until the bot's opener line gets injected,
//  so the liker doesn't vanish from Likes before the user notices them.
//

import Foundation

enum LikedByStore {
    private static let likedAtKey = "liked.by.likedAt"                 // [String: String] characterID -> ISO date
    private static let nextEligibleAtKey = "liked.by.nextEligibleAt"   // ISO date of the next allowed pick

    private static var likedAt: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: likedAtKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: likedAtKey) }
    }

    private static let isoFormatter = ISO8601DateFormatter()

    /// Whether enough time has passed since the last pick to allow another one.
    static func isEligibleForPick() -> Bool {
        guard let raw = UserDefaults.standard.string(forKey: nextEligibleAtKey),
              let next = isoFormatter.date(from: raw)
        else { return true }
        return Date() >= next
    }

    static func likedCharacterIDs() -> Set<UUID> {
        Set(likedAt.keys.compactMap(UUID.init))
    }

    static func likedAt(_ characterID: UUID) -> Date? {
        likedAt[characterID.uuidString].flatMap { isoFormatter.date(from: $0) }
    }

    /// Records this pick — the same bot never gets picked again (bkz.
    /// NotificationScheduler eligible filtresi) — and pushes the next allowed
    /// pick out by `nextPickDelay` (the same random 15-30 min window the
    /// notification itself was scheduled with).
    static func recordLike(_ characterID: UUID, nextPickDelay: TimeInterval) {
        var m = likedAt
        guard m[characterID.uuidString] == nil else { return }
        m[characterID.uuidString] = isoFormatter.string(from: Date())
        likedAt = m
        UserDefaults.standard.set(
            isoFormatter.string(from: Date().addingTimeInterval(nextPickDelay)),
            forKey: nextEligibleAtKey
        )
    }
}
