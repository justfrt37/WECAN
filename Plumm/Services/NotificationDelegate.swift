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
    private static var pendingTap: (kind: NotificationKind, characterID: UUID, level: Int?, body: String?)?

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        let userInfo = request.content.userInfo
        guard
            let typeRaw = userInfo["type"] as? String,
            let kind = NotificationKind(rawValue: typeRaw),
            let idString = userInfo["characterId"] as? String,
            let characterID = UUID(uuidString: idString)
        else { completionHandler(); return }

        Task { @MainActor in
            // Zaten teslim edilmiş sayılır — sonraki catch-up taramasında tekrar işlenmesin.
            center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
            handleTap(kind: kind, characterID: characterID, level: userInfo["level"] as? Int, body: request.content.body, navigate: true)
            completionHandler()
        }
    }

    /// Call once `store.isLoaded` becomes true — replays a tap that arrived
    /// while characters were still being fetched.
    func replayPendingTapIfNeeded() {
        guard let pending = Self.pendingTap else { return }
        Self.pendingTap = nil
        handleTap(kind: pending.kind, characterID: pending.characterID, level: pending.level, body: pending.body, navigate: true)
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

                    // Teslim edilmişi SADECE handleTap başarılı olduysa (karakter
                    // yüklüyse) sil. Karakterler henüz yüklenmediyse handleTap erken
                    // döner; navigate==false olduğu için pendingTap'e de yazılmaz —
                    // önceden silseydik teslim edilmiş proaktif mesaj tamamen kaybolurdu.
                    // Silmeyip bırakırsak bir sonraki catch-up taramasında (karakterler
                    // yüklendikten sonra) tekrar işlenir; başarıda silindiği için çift
                    // enjeksiyon olmaz.
                    let handled = self.handleTap(kind: kind, characterID: characterID, level: userInfo["level"] as? Int, body: request.content.body, navigate: false)
                    if handled {
                        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [request.identifier])
                    }
                }
            }
        }
    }

    /// Döndürdüğü Bool: karakter yüklüydü ve işlem tamamlandı mı? (catch-up
    /// yolu bununla teslim edilmiş bildirimi silip silmeyeceğine karar verir.)
    @discardableResult
    private func handleTap(kind: NotificationKind, characterID: UUID, level: Int?, body: String?, navigate: Bool) -> Bool {
        guard let character = store.characters.first(where: { $0.id == characterID }) else {
            if navigate { Self.pendingTap = (kind, characterID, level, body) }
            return false
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
            // İlk temas — henüz konuşma yok, dolayısıyla algılanacak bir sohbet
            // dili de yok. Bu ön-tanımlı açılış mesajı UYGULAMA diline uymalı
            // (bkz. kullanıcı talebi: boş yeni sohbetteki hazır mesajlar app
            // dilinde), ConversationLanguage'ın cihaz-dili fallback'ine değil.
            line = LikedYouContent.opener(language: AppLanguage.uiCode, forRole: character.personalityRole)
        case .ghosted:
            let resolvedLevel = level ?? LocalConversationStore.shared.load(for: characterID)?.level ?? 1
            line = GhostedContent.randomLine(language: language, role: character.personalityRole, vibe: character.vibe, level: resolvedLevel)
        case .jealousy:
            line = JealousyContent.randomLine(language: language, role: character.personalityRole, vibe: character.vibe)
        case .jealousyEscalation:
            // Grok-generated at schedule time (bkz. NotificationScheduler.escalationLine) —
            // baked into the notification's own body, no local dictionary to draw from.
            line = body?.isEmpty == false ? body : JealousyContent.randomLine(language: language, role: character.personalityRole, vibe: character.vibe)
        case .levelUp:
            line = nil
        case .sleepyQuestion:
            line = SleepyContent.question(language: language)
        case .sleepyGoodbye, .bedtime:
            line = SleepyContent.goodbye(language: language)
        case .missedYou:
            let resolvedLevel = level ?? LocalConversationStore.shared.load(for: characterID)?.level ?? 1
            line = MissedYouContent.randomLine(language: language, role: character.personalityRole, vibe: character.vibe, level: resolvedLevel)
        case .goodMorning:
            let resolvedLevel = level ?? LocalConversationStore.shared.load(for: characterID)?.level ?? 1
            line = GoodMorningContent.randomLine(language: language, role: character.personalityRole, vibe: character.vibe, level: resolvedLevel)
        }

        if let line {
            // SADECE "Liked You" (ilk temas) yeni bir sohbet oluşturabilir.
            // Diğer proaktif bildirimler (ghosted/jealousy/missedYou/goodMorning...)
            // yalnızca ZATEN VAR OLAN sohbete eklenir — kullanıcının SİLDİĞİ bir
            // sohbeti bildirim DİRİLTMESİN (bkz. kullanıcı talebi: "sildim geri geliyor").
            // "Sıfır yerel": mesaj SUNUCUYA yazılır (kalıcı, sohbet listesinde
            // sunucudan görünür); ghosted_at / woken_up_at'ı da sunucu kind'e
            // göre günceller (bkz. chat/index.ts injectProactive).
            injectProactive(line, kind: kind, character: character, createIfMissing: kind == .liked)
        }

        guard navigate else { return true }

        if kind == .jealousy || kind == .jealousyEscalation {
            EventLogger.shared.log("feature_used", ["feature": "jealousy_notification_tap"])
        }

        // Level-up dışındaki bot bildirimleri sadece ilgili sekmeye yönlendirir —
        // doğrudan o botun sohbetini açmaz. "Liked You" artık Beğeniler
        // sekmesine gider (bkz. LikedByStore/LikesView), diğerleri Sohbetler'e.
        switch kind {
        case .levelUp:
            store.pendingMeetRequest = MeetRequest(character: character, prefillText: "")
        case .liked:
            store.pendingTab = .likes
        case .ghosted, .jealousy, .jealousyEscalation, .sleepyQuestion, .sleepyGoodbye, .bedtime, .missedYou, .goodMorning:
            store.pendingTab = .chat
        }
        return true
    }

    /// Show the banner even while the app is active.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Proaktif bildirim satırını SUNUCUDA saklar (kalıcı) ve bellek-içi
    /// önbelleği anında günceller (UI beklemesin). Var olmayan sohbet +
    /// createIfMissing:false → hiçbir şey yapmaz (silineni diriltme).
    private func injectProactive(_ text: String, kind: NotificationKind, character: Character, createIfMissing: Bool) {
        let characterID = character.id

        // 1) Bellek-içi anlık güncelleme — kullanıcı Sohbetler'i açtığında
        //    sunucu yanıtını beklemeden mesajı görsün.
        if var stored = LocalConversationStore.shared.load(for: characterID)
            ?? (createIfMissing
                ? LocalConversationStore.Stored(messages: [], xp: 0, level: 1, summary: "", summarizedCount: 0)
                : nil) {
            stored.messages.append(Message(role: .assistant, content: text))
            // Ghosted → kullanıcı tekrar yazana kadar tüm proaktif bildirimler
            // susar (bkz. NotificationScheduler eligibility + noteUserSent).
            if kind == .ghosted { stored.ghostedAt = Date() }
            // sleepyGoodbye → uyandırma override'ı temizlenir (karakter yine uyur).
            if kind == .sleepyGoodbye { stored.wokenUpAt = nil }
            // jealousy/jealousyEscalation → kıskançlık durum makinesi (bkz.
            // NotificationScheduler jealousy bölümü, chat/index.ts injectProactive).
            if kind == .jealousy { stored.jealousyStage = 1; stored.jealousySentAt = Date() }
            if kind == .jealousyEscalation { stored.jealousyStage = 2; stored.jealousySentAt = Date() }
            LocalConversationStore.shared.save(stored, for: characterID)
            store.chatCache[characterID] = stored.messages
            store.conversationsVersion += 1
        }

        // 2) SUNUCUYA yaz (kalıcı) — sohbet listesi sunucudan beslendiği için
        //    mesajın orada kalıcı görünmesi ŞART (bkz. ChatListView server-only).
        Task { [store] in
            _ = await ChatService().injectProactiveMessage(
                character: character, kind: kind.rawValue, text: text, createIfMissing: createIfMissing
            )
            store.conversationsVersion += 1   // liste sunucudan tazelensin
        }
    }
}
