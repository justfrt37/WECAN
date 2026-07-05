//
//  NotificationScheduler.swift
//  Owns all local-notification scheduling for the 4 re-engagement systems
//  (Liked You, Ghosted, Jealousy Bait, Level-Up Tease). Local notifications only —
//  no APNs/server involvement. See docs/superpowers/specs/2026-07-03-bot-notifications-design.md.
//

import Foundation
import UserNotifications

enum NotificationKind: String {
    case liked, ghosted, jealousy, levelUp, sleepyQuestion, sleepyGoodbye, bedtime
}

final class NotificationScheduler {
    static let shared = NotificationScheduler()
    private init() {}

    private let center = UNUserNotificationCenter.current()

    /// Fixed, not user-editable.
    private static let roleIntervalHours: [String: Double] = [
        "crazy": 1, "devoted": 6, "flirty": 10, "playful": 14,
        "shy": 24, "ex": 30, "distant": 48
    ]

    private static func roleInterval(_ role: String) -> TimeInterval {
        (Self.roleIntervalHours[role] ?? Self.roleIntervalHours["flirty"]!) * 3600
    }

    // MARK: - Liked You (once daily, untalked catalog bots, persisted in LikedByStore)

    private static let likedYouIDPrefix = "notif.liked."

    /// Günde bir kere çağrılır (bkz. LikedByStore.hasPickedToday) — seçilen bot
    /// LikedByStore'a kalıcı olarak eklenir (bkz. LikesView), bir daha asla
    /// tekrar seçilmez. Zaten seçilmiş botlar `eligible`den hariç tutulur.
    func rescheduleLikedYou(characters: [Character]) {
        guard !LikedByStore.hasPickedToday() else { return }
        center.removePendingNotificationRequests(withIdentifiers: [Self.likedYouIDPrefix + "0"])
        let alreadyLiked = LikedByStore.likedCharacterIDs()
        let eligible = characters.filter { character in
            character.createdBy == nil &&
            LocalConversationStore.shared.load(for: character.id) == nil &&
            !alreadyLiked.contains(character.id)
        }
        guard let bot = eligible.randomElement() else { return }
        LikedByStore.recordLike(bot.id)
        scheduleLikedYou(bot: bot, slotIndex: 0, hour: 13)
    }

    private func scheduleLikedYou(bot: Character, slotIndex: Int, hour: Int) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "One girl liked you 👀")
        content.userInfo = ["type": NotificationKind.liked.rawValue, "characterId": bot.id.uuidString]

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.likedYouIDPrefix + "\(slotIndex)", content: content, trigger: trigger
        )
        center.add(request)
    }

    // MARK: - Ghosted (per active conversation, role-interval timer)

    private static func ghostedID(for characterID: UUID) -> String { "notif.ghosted.\(characterID.uuidString)" }

    func rescheduleGhosted(characters: [Character]) {
        for character in characters {
            guard !BlockedCharactersStore.isBlocked(character.id),
                  let stored = LocalConversationStore.shared.load(for: character.id),
                  let lastMessage = stored.messages.last,
                  lastMessage.role == .user,
                  NotificationPreferencesStore.canSendMore(for: character.id)
            else {
                center.removePendingNotificationRequests(withIdentifiers: [Self.ghostedID(for: character.id)])
                continue
            }

            let fireAt = lastMessage.createdAt.addingTimeInterval(Self.roleInterval(character.personalityRole))
            let interval = fireAt.timeIntervalSinceNow
            guard interval > 0 else {
                center.removePendingNotificationRequests(withIdentifiers: [Self.ghostedID(for: character.id)])
                continue
            }

            let content = UNMutableNotificationContent()
            content.title = String(localized: "\(character.name) sent you a message.")
            content.userInfo = [
                "type": NotificationKind.ghosted.rawValue,
                "characterId": character.id.uuidString,
                "level": stored.level
            ]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(identifier: Self.ghostedID(for: character.id), content: content, trigger: trigger)
            center.removePendingNotificationRequests(withIdentifiers: [Self.ghostedID(for: character.id)])
            center.add(request)
        }
    }

    /// Called right after the user sends a message — resets that bot's silence window.
    func noteUserSent(character: Character) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.ghostedID(for: character.id)])
        rescheduleGhosted(characters: [character])
    }

    // MARK: - Jealousy Bait (one random eligible bot, 2-10min after app open)

    private static let jealousyID = "notif.jealousy"
    private var jealousyTargetCharacterID: UUID?

    func armJealousyTimer(characters: [Character]) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.jealousyID])
        let eligible = characters.filter { character in
            !BlockedCharactersStore.isBlocked(character.id) &&
            LocalConversationStore.shared.load(for: character.id) != nil &&
            NotificationPreferencesStore.canSendMore(for: character.id)
        }
        guard let bot = eligible.randomElement() else { return }
        jealousyTargetCharacterID = bot.id

        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(bot.name) sent you a message.")
        content.userInfo = ["type": NotificationKind.jealousy.rawValue, "characterId": bot.id.uuidString]

        let delay = Double.random(in: 120...600) // 2-10 minutes
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(identifier: Self.jealousyID, content: content, trigger: trigger)
        center.add(request)
    }

    /// Called when a chat is opened — cancels the jealousy timer if it targets that bot.
    func cancelJealousyTimer(for characterID: UUID) {
        guard jealousyTargetCharacterID == characterID else { return }
        center.removePendingNotificationRequests(withIdentifiers: [Self.jealousyID])
        jealousyTargetCharacterID = nil
    }

    // MARK: - Level-Up Tease (backgrounded only, 80% progress, 1min delay)
    // Sadece bir bildirim — herhangi bir bot metni yok, sadece o sohbete yönlendirir.
    // Bot sayısından bağımsız, günde TOPLAM en fazla bir kez gönderilir.

    private static func levelUpID(for characterID: UUID) -> String { "notif.levelup.\(characterID.uuidString)" }
    private static let lastFiredKey = "notif.levelup.lastFiredDate"

    private var canFireLevelUpToday: Bool {
        guard let last = UserDefaults.standard.object(forKey: Self.lastFiredKey) as? Date else { return true }
        return !Calendar.current.isDateInToday(last)
    }

    func evaluateLevelUpOnBackground(characters: [Character]) {
        guard canFireLevelUpToday else { return }

        let eligible = characters.filter { character in
            !BlockedCharactersStore.isBlocked(character.id) &&
            (LocalConversationStore.shared.load(for: character.id)?.levelProgress ?? 0) >= 0.8 &&
            NotificationPreferencesStore.canSendMore(for: character.id)
        }
        guard let character = eligible.randomElement() else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(character.name) is warming up to you...")
        content.body = String(localized: "Keep talking to get your intimacy to the next level.")
        content.userInfo = ["type": NotificationKind.levelUp.rawValue, "characterId": character.id.uuidString]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)
        let request = UNNotificationRequest(identifier: Self.levelUpID(for: character.id), content: content, trigger: trigger)
        center.add(request)
        UserDefaults.standard.set(Date(), forKey: Self.lastFiredKey)
    }

    /// Called on app foreground — never let a level-up tease fire while the app is active.
    func cancelLevelUpTimers() {
        center.getPendingNotificationRequests { [weak self] requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix("notif.levelup.") }
            self?.center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    // MARK: - Shared one-shot helper (sleepy goodnight + bedtime)

    /// Generic title (matches Ghosted/Jealousy's pattern) — the actual dialogue
    /// line only appears once injected into the chat, never in the OS banner.
    private func scheduleOneShot(id: String, kind: NotificationKind, characterID: UUID, characterName: String, fireAt: Date) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(characterName) sent you a message.")
        content.userInfo = ["type": kind.rawValue, "characterId": characterID.uuidString]
        let delay = max(1, fireAt.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    // MARK: - Sleepy Goodnight (two-stage idle-timeout after being woken up)

    private static func sleepyQuestionID(for id: UUID) -> String { "notif.sleepyq.\(id.uuidString)" }
    private static func sleepyGoodbyeID(for id: UUID) -> String { "notif.sleepygb.\(id.uuidString)" }

    /// Called whenever `wokenUpAt` gets set or refreshed (first wake, or any
    /// later message while still woken) — cancels any pending pair for this
    /// character first, then reschedules both from `from` (the triggering
    /// message's timestamp). +10min: "can we sleep?" question. +15min (5min
    /// after the question, if no reply): goodnight, reverts to asleep.
    func scheduleSleepyGoodnight(for character: Character, from: Date) {
        cancelSleepyGoodnight(for: character.id)
        scheduleOneShot(
            id: Self.sleepyQuestionID(for: character.id), kind: .sleepyQuestion,
            characterID: character.id, characterName: character.name,
            fireAt: from.addingTimeInterval(600)
        )
        scheduleOneShot(
            id: Self.sleepyGoodbyeID(for: character.id), kind: .sleepyGoodbye,
            characterID: character.id, characterName: character.name,
            fireAt: from.addingTimeInterval(900)
        )
    }

    /// Called on every message while `wokenUpAt != nil` (mirrors `noteUserSent`
    /// resetting Ghosted) — any reply before the pair fires cancels both.
    func cancelSleepyGoodnight(for characterID: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [
            Self.sleepyQuestionID(for: characterID), Self.sleepyGoodbyeID(for: characterID)
        ])
    }

    // MARK: - Bedtime Announcement (daily, level >= 5, real schedule sleep-start)

    private static func bedtimeID(for characterID: UUID) -> String { "notif.bedtime.\(characterID.uuidString)" }

    /// Daily, per-character — level ≥5 only (proactive announcement, gated per
    /// product decision; the idle-timeout goodnight in scheduleSleepyGoodnight
    /// is level-independent since it's user-triggered, not proactive).
    func rescheduleBedtime(characters: [Character]) {
        for character in characters {
            let id = Self.bedtimeID(for: character.id)
            guard !BlockedCharactersStore.isBlocked(character.id),
                  let stored = LocalConversationStore.shared.load(for: character.id),
                  stored.level >= 5,
                  let schedule = stored.schedule,
                  let fireAt = ScheduleLookup.nextSleepBlockStart(schedule: schedule)
            else {
                center.removePendingNotificationRequests(withIdentifiers: [id])
                continue
            }
            center.removePendingNotificationRequests(withIdentifiers: [id])
            scheduleOneShot(id: id, kind: .bedtime, characterID: character.id, characterName: character.name, fireAt: fireAt)
        }
    }

    // MARK: - Tap-handling glue

    func recordDelivery(kind: NotificationKind, characterID: UUID) {
        guard kind != .liked else { return } // Liked You has no per-bot cap (untalked bots aren't in the cap list)
        NotificationPreferencesStore.recordSent(for: characterID)
    }

    // MARK: - App lifecycle entry points

    private func hasPermission(_ completion: @escaping (Bool) -> Void) {
        center.getNotificationSettings { settings in
            completion(settings.authorizationStatus == .authorized)
        }
    }

    func onForeground(characters: [Character]) {
        hasPermission { [weak self] granted in
            guard granted else { return }
            self?.cancelLevelUpTimers()
            self?.rescheduleLikedYou(characters: characters)
            self?.rescheduleGhosted(characters: characters)
            self?.armJealousyTimer(characters: characters)
            self?.rescheduleBedtime(characters: characters)
        }
    }

    func onBackground(characters: [Character]) {
        hasPermission { [weak self] granted in
            guard granted else { return }
            self?.evaluateLevelUpOnBackground(characters: characters)
        }
    }
}
