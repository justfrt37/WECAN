//
//  NotificationDelegate.swift
//  Handles taps on the 4 bot-notification types: injects the in-character line
//  into LocalConversationStore, then hands off to CharacterStore.pendingMeetRequest
//  (existing navigation pattern from the Discover meet-flow) to open that chat.
//

import Foundation
import UserNotifications

@MainActor
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let store: CharacterStore
    init(store: CharacterStore) { self.store = store }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let userInfo = response.notification.request.content.userInfo
        guard
            let typeRaw = userInfo["type"] as? String,
            let kind = NotificationKind(rawValue: typeRaw),
            let idString = userInfo["characterId"] as? String,
            let characterID = UUID(uuidString: idString),
            let character = store.characters.first(where: { $0.id == characterID })
        else { return }

        NotificationScheduler.shared.recordDelivery(kind: kind, characterID: characterID)

        let line: String
        switch kind {
        case .liked:
            line = LikedYouContent.opener(forRole: character.personalityRole)
        case .ghosted:
            let level = (userInfo["level"] as? Int) ?? LocalConversationStore.shared.load(for: characterID)?.level ?? 1
            line = GhostedContent.randomLine(role: character.personalityRole, vibe: character.vibe, level: level)
        case .jealousy:
            line = JealousyContent.randomLine(role: character.personalityRole, vibe: character.vibe)
        case .levelUp:
            line = LevelUpTeaseContent.line(forRole: character.personalityRole)
        }

        injectMessage(line, for: characterID)
        store.pendingMeetRequest = MeetRequest(character: character, prefillText: "")
    }

    /// Show the banner even while the app is active.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private func injectMessage(_ text: String, for characterID: UUID) {
        guard var stored = LocalConversationStore.shared.load(for: characterID) else { return }
        stored.messages.append(Message(role: .assistant, content: text))
        LocalConversationStore.shared.save(stored, for: characterID)
        store.chatCache.removeValue(forKey: characterID) // force ChatViewModel to reload fresh, not the stale cache
    }
}
