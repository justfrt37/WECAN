//
//  NotificationDelegate.swift
//  Handles the 4 bot-notification types: injects the in-character line into
//  LocalConversationStore as soon as the notification is DELIVERED (not only
//  when tapped — see `catchUpOnDeliveredNotifications()`), then, if the user
//  actually taps it, hands off to CharacterStore.pendingTab/pendingMeetRequest
//  (existing navigation patterns) to open the right screen.
//

import Foundation
import UserNotifications

@MainActor
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let store: CharacterStore
    init(store: CharacterStore) { self.store = store }

    /// A tap that arrived before `CharacterStore.characters` finished loading (cold
    /// launch races the notification delegate against the async character fetch).
    /// Replayed once the store finishes loading — see `replayPendingTapIfNeeded()`.
    private static var pendingTap: (kind: NotificationKind, characterID: UUID, level: Int?)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let request = response.notification.request
        let userInfo = request.content.userInfo
        guard
            let typeRaw = userInfo["type"] as? String,
            let kind = NotificationKind(rawValue: typeRaw),
            let idString = userInfo["characterId"] as? String,
            let characterID = UUID(uuidString: idString)
        else { return }

        // Zaten teslim edilmiş sayılır — sonraki catch-up taramasında tekrar işlenmesin.
        center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
        handleTap(kind: kind, characterID: characterID, level: userInfo["level"] as? Int, navigate: true)
    }

    /// Call once `store.isLoaded` becomes true — replays a tap that arrived
    /// while characters were still being fetched.
    func replayPendingTapIfNeeded() {
        guard let pending = Self.pendingTap else { return }
        Self.pendingTap = nil
        handleTap(kind: pending.kind, characterID: pending.characterID, level: pending.level, navigate: true)
    }

    /// Uygulama her ön plana geldiğinde çağrılır — kullanıcı bildirime hiç
    /// dokunmasa bile, zaten TESLİM EDİLMİŞ (ekranda gösterilmiş) bildirimlerin
    /// botun mesajını sohbete işlemesini sağlar. Yönlendirme yapmaz, sadece
    /// mesajı enjekte eder — kullanıcı hâlâ Sohbetler'i kendi açmalı.
    func catchUpOnDeliveredNotifications() {
        UNUserNotificationCenter.current().getDeliveredNotifications { [weak self] delivered in
            Task { @MainActor in
                guard let self else { return }
                for notification in delivered {
                    let request = notification.request
                    let userInfo = request.content.userInfo
                    guard
                        let typeRaw = userInfo["type"] as? String,
                        let kind = NotificationKind(rawValue: typeRaw),
                        let idString = userInfo["characterId"] as? String,
                        let characterID = UUID(uuidString: idString)
                    else { continue }

                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [request.identifier])
                    self.handleTap(kind: kind, characterID: characterID, level: userInfo["level"] as? Int, navigate: false)
                }
            }
        }
    }

    private func handleTap(kind: NotificationKind, characterID: UUID, level: Int?, navigate: Bool) {
        guard let character = store.characters.first(where: { $0.id == characterID }) else {
            if navigate { Self.pendingTap = (kind, characterID, level) }
            return
        }

        NotificationScheduler.shared.recordDelivery(kind: kind, characterID: characterID)

        // Botun bu sohbette GERÇEKTE konuştuğu dil — cihazın sistem dilinden
        // farklı olabilir (bkz. ConversationLanguage.swift).
        let language = ConversationLanguage.current(for: characterID)

        // "Warming up to you" salt bir app bildirimi — botun kendi ağzından
        // bir şey söylemez, sadece sohbete yönlendirir.
        let line: String?
        switch kind {
        case .liked:
            line = LikedYouContent.opener(language: language, forRole: character.personalityRole)
        case .ghosted:
            let resolvedLevel = level ?? LocalConversationStore.shared.load(for: characterID)?.level ?? 1
            line = GhostedContent.randomLine(language: language, role: character.personalityRole, vibe: character.vibe, level: resolvedLevel)
        case .jealousy:
            line = JealousyContent.randomLine(language: language, role: character.personalityRole, vibe: character.vibe)
        case .levelUp:
            line = nil
        case .sleepyQuestion:
            line = SleepyContent.question(language: language)
        case .sleepyGoodbye, .bedtime:
            line = SleepyContent.goodbye(language: language)
        }

        if let line {
            injectMessage(line, for: characterID)
        }

        // .sleepyGoodbye reverts the character to genuinely asleep — clear the
        // wake-override so CharacterSleepState.isEffectivelyAsleep is true again.
        if kind == .sleepyGoodbye {
            var stored = LocalConversationStore.shared.load(for: characterID)
            stored?.wokenUpAt = nil
            if let stored { LocalConversationStore.shared.save(stored, for: characterID) }
        }

        guard navigate else { return }

        // Level-up dışındaki bot bildirimleri sadece ilgili sekmeye yönlendirir —
        // doğrudan o botun sohbetini açmaz. "Liked You" artık Beğeniler
        // sekmesine gider (bkz. LikedByStore/LikesView), diğerleri Sohbetler'e.
        switch kind {
        case .levelUp:
            store.pendingMeetRequest = MeetRequest(character: character, prefillText: "")
        case .liked:
            store.pendingTab = .likes
        case .ghosted, .jealousy, .sleepyQuestion, .sleepyGoodbye, .bedtime:
            store.pendingTab = .chat
        }
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
        // "Liked You" bildirimleri hiç konuşulmamış botlar için gelir — o yüzden
        // henüz LocalConversationStore kaydı yok; bu mesaj sohbetin İLK mesajı olur.
        var stored = LocalConversationStore.shared.load(for: characterID)
            ?? LocalConversationStore.Stored(messages: [], xp: 0, level: 1, summary: "", summarizedCount: 0)
        stored.messages.append(Message(role: .assistant, content: text))
        LocalConversationStore.shared.save(stored, for: characterID)
        store.chatCache.removeValue(forKey: characterID) // force ChatViewModel to reload fresh, not the stale cache
        store.conversationsVersion += 1
    }
}
