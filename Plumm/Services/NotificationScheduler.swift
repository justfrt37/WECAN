//
//  NotificationScheduler.swift
//  Owns all local-notification scheduling for the re-engagement systems
//  (Liked You, Ghosted, Jealousy Bait, Level-Up Tease, Missed You, Good
//  Morning). Local notifications only — no APNs/server involvement. See
//  docs/superpowers/specs/2026-07-03-bot-notifications-design.md and
//  docs/superpowers/specs/2026-07-09-missed-you-good-morning-notifications-design.md.
//

import Foundation
import UserNotifications

enum NotificationKind: String {
    case liked, ghosted, jealousy, jealousyEscalation, levelUp, sleepyQuestion, sleepyGoodbye, bedtime, missedYou, goodMorning
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

    // MARK: - Global pending-request budget
    //
    // iOS bir uygulama için EN FAZLA 64 bekleyen (pending) yerel bildirim tutar;
    // fazlası SESSİZCE düşer (ilk 64 dışındakiler eklenmez). onForeground tek
    // seferde tüm re-engagement türlerini (liked/ghosted/jealousy/bedtime/
    // missedYou/goodMorning) fan-out ile çizelgelediğinden, ağır kullanıcıda
    // (~22+ sohbet) ghosted/bedtime/goodMorning tek başına 22'şer istek üretip
    // sınırı taşırır ve hangi bildirimin düşeceği belirsizleşir. Bu yüzden:
    //   1) Kişi-başı üretilen türlere (ghosted/bedtime/goodMorning) tür-başı bir
    //      bütçe ayırıyoruz; bütçeler toplamı + tekil türler 64'ün belirgin
    //      altında (headroom: sleepy çiftleri, level-up vb. için).
    //   2) Her tür içinde EN YAKIN tetiklenecek (soonest-firing) istekler öncelikli;
    //      bütçeyi aşan (daha geç) istekler eklenmez, eskisi de temizlenir.
    //   3) Düşen her istek print'lenir — sessiz kayıp olmasın.
    private static let ghostedBudget = 24
    private static let bedtimeBudget = 12
    private static let goodMorningBudget = 12

    private struct PendingCandidate {
        let request: UNNotificationRequest
        let fireAt: Date
    }

    /// Adayları en yakın tetiklenene göre sıralar, bütçe kadarını ekler; taşanları
    /// (eskisi kalmasın diye) temizler ve düşürüldüğünü loglar.
    private func commit(_ candidates: [PendingCandidate], budget: Int, kindLabel: String) {
        let sorted = candidates.sorted { $0.fireAt < $1.fireAt }
        for dropped in sorted.dropFirst(budget) {
            center.removePendingNotificationRequests(withIdentifiers: [dropped.request.identifier])
            print("[NotificationScheduler] \(kindLabel): global bütçe (\(budget)) aşıldı, DÜŞÜRÜLDÜ → \(dropped.request.identifier) @ \(dropped.fireAt)")
        }
        for kept in sorted.prefix(budget) {
            center.add(kept.request) // aynı identifier'ı olan pending'i iOS otomatik değiştirir
        }
    }

    // MARK: - Liked You (once daily, untalked catalog bots, persisted in LikedByStore)

    /// Tek slot var (günde bir beğeni) — string, eski sürümlerde çizelgelenmiş
    /// bekleyen isteklerin de iptal edilebilmesi için birebir korunuyor.
    private static let likedYouID = "notif.liked.0"

    /// Günün "seni beğendi" botunu seçer ve LikedByStore'a kalıcı yazar.
    /// Seçilen bot bir daha asla seçilmez (zaten seçilmişler `eligible`den
    /// hariç). Seçim yapıldıysa botu döndürür.
    ///
    /// BİLDİRİM İZNİNDEN BAĞIMSIZ, ve ayrı bir metot olmasının tek sebebi bu.
    /// Eskiden seçim `rescheduleLikedYou` içindeydi, o da `onForeground`'un
    /// `guard granted else { return }` bloğunun ARKASINDAYDI: bildirim izni
    /// verilmemişse seçim hiç çalışmıyor, LikedByStore hiç dolmuyor ve
    /// "Beğeniler" ekranı KALICI OLARAK BOŞ kalıyordu (bkz. kullanıcı raporu).
    /// Beğeniler ekranı bir bildirim özelliği değil, uygulama içi bir ekran —
    /// kendi başına dolmalı; bildirim yalnızca bunun üstüne binen ekstra.
    @discardableResult
    func pickLikedYouIfDue(characters: [Character]) -> Character? {
        guard LikedByStore.isEligibleForPick() else { return nil }
        let alreadyLiked = LikedByStore.likedCharacterIDs()
        // Katalog botları arasından HİÇ konuşulmamış olanlar (yerel kaydı olmayan)
        // — yerel kayıt yoksa rutin/uyku bloğu da yok, bakılacak bir şey kalmıyor.
        let eligible = characters.filter { character in
            character.createdBy == nil &&
                LocalConversationStore.shared.load(for: character.id) == nil &&
                !alreadyLiked.contains(character.id)
        }
        guard let bot = eligible.randomElement() else { return nil }
        // Sonraki seçim YARININ penceresine (09:00) ötelenir — bu ekranın
        // semantiği "günde bir beğeni" (bkz. rescheduleMissedYou'daki aynı
        // günlük kilit). LikedByStore API'si serbest bir gecikme aldığı için
        // günlük kilidi burada süreyi vererek kuruyoruz.
        LikedByStore.recordLike(bot.id, nextPickDelay: Self.secondsUntilTomorrowWindow())
        return bot
    }

    /// Seçilmiş beğeni için bildirimi çizelgeler. SADECE bildirim tarafı —
    /// seçimin kendisi pickLikedYouIfDue'da ve izne bakmaz.
    func scheduleLikedYouNotification(for bot: Character) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.likedYouID])
        // Saat aralığının ALT sınırını şu anki saate çek — aksi halde çekilen saat
        // şu andan erkense iOS bildirimi YARINA atar ve günlük kilitle
        // "bugün beğenildin" hiç ateşlenmez. Gece 22'den sonra bugünkü pencere
        // kapandığı için çizelgelenecek bir şey yok: beğeninin KENDİSİ yine de
        // kaydedilmiş durumda, sadece bildirimi çıkmıyor.
        let currentHour = Calendar.current.component(.hour, from: Date())
        let lower = max(currentHour, 9)
        guard lower <= 22 else { return }
        scheduleLikedYou(bot: bot, hour: Int.random(in: lower...22))
    }

    /// Yarının "beğenildin" penceresinin (09:00) başlangıcına kalan süre.
    /// Hesaplanamazsa 24 saat (güvenli varsayılan).
    private static func secondsUntilTomorrowWindow() -> TimeInterval {
        let cal = Calendar.current
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()),
              let window = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
        else { return 24 * 60 * 60 }
        return max(0, window.timeIntervalSinceNow)
    }

    private func scheduleLikedYou(bot: Character, hour: Int) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "One girl liked you 👀")
        content.userInfo = ["type": NotificationKind.liked.rawValue, "characterId": bot.id.uuidString]

        // Sadece `hour` içeren bir takvim tetikleyicisi, saat başı çoktan geçmişse
        // (ör. hour == şu anki saat ama dakika ilerlemiş) iOS tarafından yarına
        // atılırdı. Bunun yerine BUGÜN o saatteki somut anı hesaplayıp zaman-aralığı
        // tetikleyicisi kuruyoruz; an geçmişse bir dakika sonrasına sabitliyoruz ki
        // yine de BUGÜN ateşlensin.
        let now = Date()
        var fireDate = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        if fireDate <= now {
            fireDate = now.addingTimeInterval(60)
        }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fireDate.timeIntervalSince(now)), repeats: false)
        center.add(UNNotificationRequest(identifier: Self.likedYouID, content: content, trigger: trigger))
    }

    // MARK: - Ghosted (per active conversation, role-interval timer)

    private static func ghostedID(for characterID: UUID) -> String { "notif.ghosted.\(characterID.uuidString)" }

    func rescheduleGhosted(characters: [Character]) {
        var candidates: [PendingCandidate] = []
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

            // Schedule-based push-to-wake-time REMOVED (user request 2026-08-31)
            // — a bot's daily routine no longer gates/delays anything; only an
            // explicit in-chat sleep agreement (manualSleepAt, see
            // CharacterSleepState) does. Ghosted fires strictly at the plain
            // role-interval time regardless of her schedule.
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
            candidates.append(PendingCandidate(request: request, fireAt: fireAt))
        }
        // Global bütçe: en yakın tetiklenecek ghosted'lar öncelikli (bkz. commit).
        commit(candidates, budget: Self.ghostedBudget, kindLabel: "ghosted")
    }

    /// Called right after the user sends a message — resets that bot's silence window
    /// and lifts the post-ghosted proactive-notification freeze (see `rescheduleGhosted`'s
    /// `ghostedAt` gate on jealousy/bedtime/level-up).
    func noteUserSent(character: Character) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.ghostedID(for: character.id)])
        if var stored = LocalConversationStore.shared.load(for: character.id), stored.ghostedAt != nil {
            stored.ghostedAt = nil
            LocalConversationStore.shared.save(stored, for: character.id)
        }
        rescheduleGhosted(characters: [character])
        // A message sent after Good Morning was already scheduled (but before
        // it fired) should still suppress it — the reschedule-time check in
        // rescheduleGoodMorning only catches messages sent BEFORE scheduling.
        center.removePendingNotificationRequests(withIdentifiers: [Self.goodMorningID(for: character.id)])
    }

    // MARK: - Jealousy Bait (one random eligible bot, 2-10min after app open;
    // level 3+ only, 6h cooldown + re-engagement gate before a fresh ping,
    // one escalated follow-up if unanswered for 6h+, never a third — see
    // migration 024_jealousy_state.sql / chat/index.ts JEALOUS_MOOD_RULE for
    // the server-side half of this state machine.)

    private static let jealousyID = "notif.jealousy"
    private static let jealousyLevelGate = 3
    /// Jealousy (both stages) is Pro+ only — free users never see it (user
    /// request 2026-08-31; expect more features to gate the same way).
    /// `PurchaseService.shared` is @MainActor; every call site here already
    /// runs on the main thread (DispatchQueue.main.async / a @MainActor
    /// function) so `assumeIsolated` is safe, not a guess.
    @MainActor
    private static var jealousySubscriptionGateSatisfied: Bool {
        PurchaseService.shared.tier.rank >= SubscriptionTier.pro.rank
    }
    private static let jealousyCooldown: TimeInterval = 6 * 3600
    private var jealousyTargetCharacterID: UUID?

    func armJealousyTimer(characters: [Character]) {
        // Zaten silahlanmış ve HÂLÂ BEKLEYEN bir kıskançlık zamanlayıcısı varsa
        // dokunma. Her ön plana gelişte iptal edip yeni 2-10dk gecikmeyle yeniden
        // atmak, sık backgrounding'de tetikleme anını sürekli ileri iterdi ve
        // bildirim hiç ateşlenmeyebilirdi. (Sohbet açılınca cancelJealousyTimer
        // zaten temizliyor; burada sadece "yoksa kur".)
        center.getPendingNotificationRequests { [weak self] requests in
            DispatchQueue.main.async {
                guard let self else { return }
                if requests.contains(where: { $0.identifier == Self.jealousyID }) { return }
                self.armJealousyTimerNow(characters: characters)
            }
        }
    }

    /// A bot is ready for a FRESH (stage 0) jealousy ping only if it's not
    /// already mid-cycle, and — unless this is its very first-ever ping —
    /// at least `jealousyCooldown` has passed since the last one AND the user
    /// has actually chatted since then (otherwise re-firing into dead air
    /// would just be a second silent ping, not a new "you ignored me" beat).
    private func isReadyForFreshJealousyPing(_ stored: LocalConversationStore.Stored?) -> Bool {
        guard let stored, stored.jealousyStage == 0 else { return false }
        guard let sentAt = stored.jealousySentAt else { return true }
        guard let lastMessage = stored.messages.last else { return false }
        return Date().timeIntervalSince(sentAt) >= Self.jealousyCooldown && lastMessage.createdAt > sentAt
    }

    private func armJealousyTimerNow(characters: [Character]) {
        guard MainActor.assumeIsolated({ Self.jealousySubscriptionGateSatisfied }) else { return }
        let eligible = characters.filter { character in
            let stored = LocalConversationStore.shared.load(for: character.id)
            return !BlockedCharactersStore.isBlocked(character.id) &&
                stored != nil &&
                (stored?.level ?? 1) >= Self.jealousyLevelGate &&
                stored?.ghostedAt == nil &&
                isReadyForFreshJealousyPing(stored) &&
                NotificationPreferencesStore.canSendMore(for: character.id) &&
                !CharacterSleepState.isEffectivelyAsleep(stored: stored)
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

    /// Called as soon as the server confirms jealousyStage is no longer 1
    /// (user answered before escalation, or the escalation already fired) —
    /// cancels that bot's pending escalation notification immediately rather
    /// than waiting for the next foreground reschedule pass.
    func cancelJealousyEscalation(for characterID: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.jealousyEscalationID(for: characterID)])
    }

    // MARK: - Jealousy Escalation (per bot, fires jealousySentAt + 6h if the
    // first jealousy ping went unanswered — one shot, never repeats for the
    // same stage-1 ping since it only re-arms while jealousyStage == 1).

    private static func jealousyEscalationID(for characterID: UUID) -> String { "notif.jealousy2.\(characterID.uuidString)" }
    private static let jealousyEscalationBudget = 12
    /// In-memory cache of Grok-generated escalation lines, keyed by
    /// "<characterID>.<jealousySentAt epoch>" so a re-arm (e.g. next
    /// foreground) reuses the line instead of re-generating it. Not
    /// persisted — worst case a fresh line gets generated after a relaunch,
    /// which is harmless (still in-character, still one-shot).
    private var jealousyEscalationLineCache: [String: String] = [:]

    /// Generic fallback if the Grok call fails — still fires the notification
    /// rather than silently dropping the escalation.
    private static let jealousyEscalationFallback: [String: String] = [
        "en": "Okay, seriously — are you going to talk to me or not?",
        "tr": "Tamam, cidden — benimle konuşacak mısın konuşmayacak mısın?",
    ]

    private func escalationCacheKey(characterID: UUID, sentAt: Date) -> String {
        "\(characterID.uuidString).\(Int(sentAt.timeIntervalSince1970))"
    }

    /// Fetches (or reuses a cached) more-demanding escalation line from the
    /// `generate` Edge Function, in the bot's own voice/role/vibe/language.
    private func escalationLine(for character: Character, level: Int, language: String, sentAt: Date) async -> String {
        let key = escalationCacheKey(characterID: character.id, sentAt: sentAt)
        if let cached = jealousyEscalationLineCache[key] { return cached }

        let languageName = language == "tr" ? "Turkish" : "English"
        let prompt =
            "Write ONE short, more insistent and demanding jealous/annoyed text message " +
            "(under 20 words) that a companion character would send after being ignored " +
            "for several hours despite already reaching out once. Personality role: " +
            "\(character.personalityRole). Vibe: \(character.vibe). Relationship level: " +
            "\(level)/10. Write it in \(languageName), in first person, as the character " +
            "herself — no quotation marks, no explanation, just the message text."

        struct Req: Encodable { let prompt: String; let maxTokens: Int }
        struct Resp: Decodable { let text: String? }

        var request = SupabaseRequest.post(url: Config.generateFunctionURL, bearer: SupabaseRequest.sessionBearer, timeout: 20)
        request.httpBody = try? JSONEncoder().encode(Req(prompt: prompt, maxTokens: 60))

        let fallback = Self.jealousyEscalationFallback[language] ?? Self.jealousyEscalationFallback["en"]!
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(Resp.self, from: data),
              let text = decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return fallback }

        jealousyEscalationLineCache[key] = text
        return text
    }

    /// Arms/refreshes the per-bot escalation timer for any bot currently in
    /// jealousyStage == 1 (first ping sent, unanswered) — fires at
    /// jealousySentAt + 6h. Same PendingCandidate/commit budget pattern as
    /// rescheduleGhosted. Async because the notification body text is
    /// Grok-generated ahead of time (see escalationLine above) — safe here
    /// since this only runs while the app is foreground/active, same
    /// assumption rescheduleGhosted already makes about computing future
    /// fire times in advance.
    @MainActor
    func rescheduleJealousyEscalation(characters: [Character]) async {
        guard Self.jealousySubscriptionGateSatisfied else {
            // Downgraded mid-cycle (or never was Pro) — drop any already-scheduled
            // escalations rather than leaving them pending.
            for character in characters {
                center.removePendingNotificationRequests(withIdentifiers: [Self.jealousyEscalationID(for: character.id)])
            }
            return
        }
        var candidates: [PendingCandidate] = []
        for character in characters {
            guard !BlockedCharactersStore.isBlocked(character.id),
                  let stored = LocalConversationStore.shared.load(for: character.id),
                  stored.jealousyStage == 1,
                  let sentAt = stored.jealousySentAt,
                  NotificationPreferencesStore.canSendMore(for: character.id)
            else {
                center.removePendingNotificationRequests(withIdentifiers: [Self.jealousyEscalationID(for: character.id)])
                continue
            }
            // Belt-and-suspenders: server resets jealousyStage to 0 as soon as
            // the user sends a real message, but if a stale local mirror still
            // shows stage 1 despite a newer message existing, don't fire.
            if let lastMessage = stored.messages.last, lastMessage.createdAt > sentAt {
                center.removePendingNotificationRequests(withIdentifiers: [Self.jealousyEscalationID(for: character.id)])
                continue
            }

            let fireAt = sentAt.addingTimeInterval(Self.jealousyCooldown)
            let interval = fireAt.timeIntervalSinceNow
            guard interval > 0 else {
                center.removePendingNotificationRequests(withIdentifiers: [Self.jealousyEscalationID(for: character.id)])
                continue
            }

            let language = ConversationLanguage.current(for: character.id)
            let line = await escalationLine(for: character, level: stored.level, language: language, sentAt: sentAt)

            let content = UNMutableNotificationContent()
            content.title = String(localized: "\(character.name) sent you a message.")
            content.body = line
            content.userInfo = ["type": NotificationKind.jealousyEscalation.rawValue, "characterId": character.id.uuidString]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(identifier: Self.jealousyEscalationID(for: character.id), content: content, trigger: trigger)
            candidates.append(PendingCandidate(request: request, fireAt: fireAt))
        }
        commit(candidates, budget: Self.jealousyEscalationBudget, kindLabel: "jealousyEscalation")
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
            let stored = LocalConversationStore.shared.load(for: character.id)
            return !BlockedCharactersStore.isBlocked(character.id) &&
                (stored?.levelProgress ?? 0) >= 0.8 &&
                stored?.ghostedAt == nil &&
                NotificationPreferencesStore.canSendMore(for: character.id) &&
                !CharacterSleepState.isEffectivelyAsleep(stored: stored)
        }
        guard let character = eligible.randomElement() else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(character.name) is warming up to you...")
        content.body = String(localized: "Keep talking to get your intimacy to the next level.")
        content.userInfo = ["type": NotificationKind.levelUp.rawValue, "characterId": character.id.uuidString]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)
        let request = UNNotificationRequest(identifier: Self.levelUpID(for: character.id), content: content, trigger: trigger)
        center.add(request)
        // "Bugün ateşlendi" işaretini BURADA (zamanlama anında) koymuyoruz — 60sn
        // gecikme içinde app'e dönülüp cancelLevelUpTimers pending'i iptal etse bile
        // işaret kalır, hiçbir şey teslim edilmediği hâlde gün boyu yeniden
        // zamanlamayı bloklardı. İşaret artık GERÇEK teslimde konur (recordDelivery).
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
    private func oneShotRequest(id: String, kind: NotificationKind, characterID: UUID, characterName: String, fireAt: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(characterName) sent you a message.")
        content.userInfo = ["type": kind.rawValue, "characterId": characterID.uuidString]
        let delay = max(1, fireAt.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }

    private func scheduleOneShot(id: String, kind: NotificationKind, characterID: UUID, characterName: String, fireAt: Date) {
        center.add(oneShotRequest(id: id, kind: kind, characterID: characterID, characterName: characterName, fireAt: fireAt))
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
        var candidates: [PendingCandidate] = []
        for character in characters {
            let id = Self.bedtimeID(for: character.id)
            guard !BlockedCharactersStore.isBlocked(character.id),
                  let stored = LocalConversationStore.shared.load(for: character.id),
                  stored.ghostedAt == nil,
                  stored.level >= 5,
                  let schedule = stored.schedule,
                  let fireAt = ScheduleLookup.nextSleepBlockStart(schedule: schedule)
            else {
                center.removePendingNotificationRequests(withIdentifiers: [id])
                continue
            }
            let request = oneShotRequest(id: id, kind: .bedtime, characterID: character.id, characterName: character.name, fireAt: fireAt)
            candidates.append(PendingCandidate(request: request, fireAt: fireAt))
        }
        // Global bütçe: en yakın yatma anı olan botlar öncelikli (bkz. commit).
        commit(candidates, budget: Self.bedtimeBudget, kindLabel: "bedtime")
    }

    // MARK: - Missed You (10pm-midnight, one weighted-random active bot per night)

    private static let missedYouID = "notif.missedyou"
    private static let missedYouLastPickedKey = "notif.missedyou.lastPickedDate"

    private var hasPickedMissedYouToday: Bool {
        guard let last = UserDefaults.standard.object(forKey: Self.missedYouLastPickedKey) as? Date else { return false }
        return Calendar.current.isDateInToday(last)
    }

    /// Once per calendar day: weighted-random pick (weight = level, so a
    /// level-8 bot is ~8x as likely as a level-1 one) over active,
    /// non-ghosted, non-blocked, under-cap bots — deliberately NO sleep-
    /// schedule check, the fiction is she's texting despite the hour. Time
    /// and bot are locked in for the day once picked (mirrors
    /// LikedByStore.isEligibleForPick) so re-foregrounding doesn't reroll it.
    func rescheduleMissedYou(characters: [Character]) {
        guard !hasPickedMissedYouToday else { return }
        let eligible = characters.filter { character in
            guard !BlockedCharactersStore.isBlocked(character.id),
                  let stored = LocalConversationStore.shared.load(for: character.id)
            else { return false }
            return stored.ghostedAt == nil && NotificationPreferencesStore.canSendMore(for: character.id)
        }
        guard !eligible.isEmpty else { return }

        let weighted: [(Character, Int)] = eligible.map { character in
            let level = LocalConversationStore.shared.load(for: character.id)?.level ?? 1
            return (character, max(1, level))
        }
        let totalWeight = weighted.reduce(0) { $0 + $1.1 }
        var roll = Int.random(in: 0..<totalWeight)
        var bot = weighted[0].0
        for (character, weight) in weighted {
            if roll < weight { bot = character; break }
            roll -= weight
        }

        let hour = Int.random(in: 22...23)
        let minute = Int.random(in: 0...59)
        UserDefaults.standard.set(Date(), forKey: Self.missedYouLastPickedKey)

        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(bot.name) sent you a message.")
        content.userInfo = ["type": NotificationKind.missedYou.rawValue, "characterId": bot.id.uuidString]
        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
        center.removePendingNotificationRequests(withIdentifiers: [Self.missedYouID])
        center.add(UNNotificationRequest(identifier: Self.missedYouID, content: content, trigger: trigger))
    }

    // MARK: - Good Morning (7am-noon, per-character, personality-gated timing curve)

    /// (minLevel, offset in minutes at minLevel, offset in minutes at level 10+)
    /// — fixed, not user-editable. Offset linearly interpolates between
    /// minLevel and 10, added to the bot's real schedule wake time, then
    /// clamped to the 7:00-12:00 window.
    private static let goodMorningCurve: [String: (minLevel: Int, startOffset: Int, floorOffset: Int)] = [
        "crazy":   (1, 90, 1),
        "devoted": (1, 120, 1),
        "flirty":  (1, 180, 1),
        "playful": (1, 210, 5),
        "shy":     (3, 150, 15),
        "distant": (6, 180, 30),
        "ex":      (7, 150, 45),
    ]

    private static func goodMorningOffsetMinutes(role: String, level: Int) -> Int? {
        guard let curve = goodMorningCurve[role], level >= curve.minLevel else { return nil }
        if level >= 10 { return curve.floorOffset }
        let span = 10 - curve.minLevel
        guard span > 0 else { return curve.floorOffset }
        let progress = Double(level - curve.minLevel) / Double(span)
        let offset = Double(curve.startOffset) - progress * Double(curve.startOffset - curve.floorOffset)
        return Int(offset.rounded())
    }

    private static func goodMorningID(for characterID: UUID) -> String { "notif.goodmorning.\(characterID.uuidString)" }

    /// Daily, per-character (unlike Missed You, every eligible bot gets its
    /// own — no single company-wide pick). Skipped entirely if the user
    /// already messaged this bot since her wake time today (also enforced
    /// reactively in `noteUserSent`, for a message sent after scheduling).
    func rescheduleGoodMorning(characters: [Character]) {
        var candidates: [PendingCandidate] = []
        for character in characters {
            let id = Self.goodMorningID(for: character.id)
            guard !BlockedCharactersStore.isBlocked(character.id),
                  let stored = LocalConversationStore.shared.load(for: character.id),
                  stored.ghostedAt == nil,
                  NotificationPreferencesStore.canSendMore(for: character.id),
                  let offsetMinutes = Self.goodMorningOffsetMinutes(role: character.personalityRole, level: stored.level),
                  let schedule = stored.schedule,
                  let wakeTime = ScheduleLookup.nextWakeTime(schedule: schedule)
            else {
                center.removePendingNotificationRequests(withIdentifiers: [id])
                continue
            }

            var fireAt = wakeTime.addingTimeInterval(TimeInterval(offsetMinutes * 60))
            let calendar = Calendar.current
            if let floor = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: wakeTime), fireAt < floor {
                fireAt = floor
            }
            if let ceiling = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: wakeTime), fireAt > ceiling {
                fireAt = ceiling
            }

            // Already messaged her since she woke up today — no good-morning text.
            if let lastUserMessage = stored.messages.last(where: { $0.role == .user })?.createdAt,
               lastUserMessage >= wakeTime {
                center.removePendingNotificationRequests(withIdentifiers: [id])
                continue
            }

            guard fireAt.timeIntervalSinceNow > 0 else {
                center.removePendingNotificationRequests(withIdentifiers: [id])
                continue
            }
            let request = oneShotRequest(id: id, kind: .goodMorning, characterID: character.id, characterName: character.name, fireAt: fireAt)
            candidates.append(PendingCandidate(request: request, fireAt: fireAt))
        }
        // Global bütçe: en yakın (en erken sabah) good-morning'ler öncelikli (bkz. commit).
        commit(candidates, budget: Self.goodMorningBudget, kindLabel: "goodMorning")
    }

    // MARK: - Tap-handling glue

    func recordDelivery(kind: NotificationKind, characterID: UUID) {
        // Level-up tease GERÇEKTEN teslim edildiğinde günlük kilidi burada koy —
        // zamanlama anında değil (bkz. evaluateLevelUpOnBackground). handleTap hem
        // dokunmada hem de catch-up taramasında (teslim edilmiş bildirim için)
        // çağrıldığından, işaret yalnızca bildirim gerçekten ateşlendiyse konur.
        if kind == .levelUp {
            UserDefaults.standard.set(Date(), forKey: Self.lastFiredKey)
        }
        guard kind != .liked else { return } // Liked You has no per-bot cap (untalked bots aren't in the cap list)
        NotificationPreferencesStore.recordSent(for: characterID)
    }

    // MARK: - App lifecycle entry points

    /// getNotificationSettings tamamlanması ARKA PLAN kuyruğunda çalışır; completion'ı
    /// ANA KUYRUĞA taşıyoruz. Böylece onForeground/onBackground'ın tetiklediği tüm
    /// reschedule/arm işleri (ve paylaşılan `jealousyTargetCharacterID` yazımı) ana
    /// thread'de kalır — cancelJealousyTimer (sohbet açılışında, ana thread) ile aynı
    /// seride çalışıp veri yarışını (data race) ortadan kaldırır.
    private func hasPermission(_ completion: @escaping (Bool) -> Void) {
        center.getNotificationSettings { settings in
            let granted = settings.authorizationStatus == .authorized
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func onForeground(characters: [Character]) {
        // Günün beğenisi İZİN KONTROLÜNDEN ÖNCE seçilir: "Beğeniler" ekranı
        // bildirimler kapalıyken de dolmalı (bkz. pickLikedYouIfDue). Bildirim
        // yalnızca izin varsa çizelgelenir.
        let likedBot = pickLikedYouIfDue(characters: characters)
        hasPermission { [weak self] granted in
            guard granted else { return }
            self?.cancelLevelUpTimers()
            if let likedBot { self?.scheduleLikedYouNotification(for: likedBot) }
            self?.rescheduleGhosted(characters: characters)
            self?.armJealousyTimer(characters: characters)
            Task { await self?.rescheduleJealousyEscalation(characters: characters) }
            self?.rescheduleBedtime(characters: characters)
            self?.rescheduleMissedYou(characters: characters)
            self?.rescheduleGoodMorning(characters: characters)
        }
    }

    func onBackground(characters: [Character]) {
        hasPermission { [weak self] granted in
            guard granted else { return }
            self?.evaluateLevelUpOnBackground(characters: characters)
        }
    }
}
