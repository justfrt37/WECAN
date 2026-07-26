//
//  NotificationPreferencesStore.swift
//  Per-bot daily notification caps (Ghosted + Jealousy + Level-Up combined) —
//  device-local only, mirrors BlockedCharactersStore's pattern.
//  nil cap = unlimited (∞). 0 = None (fully muted). Positive = max per day.
//

import Foundation

enum NotificationPreferencesStore {
    private static let capsKey = "notif.dailyCaps"           // [String: Int] — characterID -> cap (absent = unlimited)
    private static let countsKey = "notif.dailyCounts"       // [String: Int] — characterID -> count sent today
    private static let countsDateKey = "notif.dailyCounts.date" // ISO date string for the count window

    private static var caps: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: capsKey) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: capsKey) }
    }

    private static var counts: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: countsKey) }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    /// Resets the count table if we've crossed into a new local day.
    private static func rolloverIfNeeded() {
        let today = dayFormatter.string(from: Date())
        let storedDay = UserDefaults.standard.string(forKey: countsDateKey)
        guard storedDay != today else { return }
        UserDefaults.standard.set(today, forKey: countsDateKey)
        counts = [:]
    }

    static func dailyCap(for characterID: UUID) -> Int? {
        caps[characterID.uuidString]
    }

    /// Pass `nil` for unlimited (∞), `0` for None.
    static func setDailyCap(_ cap: Int?, for characterID: UUID) {
        var c = caps
        if let cap {
            c[characterID.uuidString] = cap
        } else {
            c.removeValue(forKey: characterID.uuidString)
        }
        caps = c
    }

    static func canSendMore(for characterID: UUID) -> Bool {
        rolloverIfNeeded()
        guard let cap = dailyCap(for: characterID) else { return true } // unlimited
        let sentToday = counts[characterID.uuidString] ?? 0
        return sentToday < cap
    }

    static func recordSent(for characterID: UUID) {
        rolloverIfNeeded()
        var c = counts
        c[characterID.uuidString] = (c[characterID.uuidString] ?? 0) + 1
        counts = c
    }
}
