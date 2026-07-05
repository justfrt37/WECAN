# Character Sleep-State Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give sleeping characters a real, persisted sleep state — notifications never fire while genuinely asleep, waking persists for the rest of a conversation instead of re-triggering every message, an idle-woken character proactively asks to go back to sleep, characters announce real bedtime daily (level ≥5 only), and users can naturally ask a character to sleep early if it's close to their actual bedtime.

**Architecture:** Two new optional fields on the existing per-character local store (`wokenUpAt`, `manualSleepAt`) back a single pure function, `CharacterSleepState.isEffectivelyAsleep`, that becomes the one source of truth every other piece checks. Two new local-notification kinds (paired `.sleepyQuestion`/`.sleepyGoodbye`, plus a separate `.bedtime`) follow the exact scheduling/injection pattern the four existing notification types already use. Server-side, one new stable rule + one new per-turn dynamic signal (kept out of the system prompt, following the prompt-caching fix already in place) let Grok naturally agree or decline an in-chat sleep request, confirmed by a small classifier call.

**Tech Stack:** SwiftUI/`@Observable`, `UserNotifications`, Supabase Edge Functions (Deno/TypeScript), xAI Grok.

## Global Constraints

- **No automated test suite** in this repo (no XCTest target, no Deno test framework) — backend tasks verify via `curl` against the deployed function with exact expected output; Swift tasks end with a manual read-through checklist instead of a compiled test (no Xcode in this sandbox — `xcode-select -p` → Command Line Tools only, SourceKit diagnostics are known-unreliable noise on definitely-correct symbols). Flag a real Xcode build + on-device smoke test as still owed once all tasks are done.
- Deploy: `SUPABASE_ACCESS_TOKEN=<PAT — see project memory, never hardcode> npx supabase functions deploy <name> --project-ref ohpvhgwjmrfjclnumgnm --no-verify-jwt`, run from `/Users/furkanozsoy/Desktop/Projects/aigf/WECAN`. **Never write the literal PAT into any committed file** — see `[[feedback_no_hardcoded_secrets_in_docs]]`, this happened twice already.
- DDL via Management API — not needed for this plan (no schema changes).
- New/edited instructional Grok prompt strings must be written in **English** (`[[feedback_grok_prompts_english]]`).
- Bot-dialogue content (character's own chat lines, as opposed to UI strings) uses the `ConversationLanguage` (`tr`/`en` only, on-device `NLLanguageRecognizer`) pattern that `GhostedContent`/`JealousyContent`/`LikedYouContent` already use — NOT the `Localizable.xcstrings` 6-language UI catalog. Do not add xcstrings entries for `SleepyContent`.
- Dynamic per-turn context (anything that changes message-to-message, like time-of-day or "is it near bedtime") must go in the trailing user message (`turnContext` in `chat/index.ts`), never baked into the `system` string — breaks xAI prompt-caching prefix-match otherwise (see `supabase/functions/chat/index.ts`'s existing `turnContext` handling, already fixed this session).

---

### Task 1: `LocalConversationStore.Stored` — `wokenUpAt`/`manualSleepAt` fields

**Files:**
- Modify: `aiGirlfriend/Services/LocalConversationStore.swift:16-77`

**Interfaces:**
- Produces: `Stored.wokenUpAt: Date?`, `Stored.manualSleepAt: Date?` — read/written by every later task in this plan via `LocalConversationStore.shared.load(for:)`/`.save(_:for:)`.

- [ ] **Step 1: Add the two fields, update `CodingKeys`, the manual `init`, `init(from:)`, and `encode(to:)`**

Find the `Stored` struct (`LocalConversationStore.swift:16-77`):

```swift
    struct Stored: Codable {
        var messages: [Message]       // tüm gerçek mesajlar (görüntüleme için)
        var xp: Int                   // eski mutlak XP alanı — artık kullanılmıyor, geriye dönük uyum için duruyor
        var level: Int
        var summary: String           // özetlenmiş eski mesajlar
        var summarizedCount: Int      // kaç mesaj özetlendi
        var msgCounter: Int = 0       // terfi eşiği için mesaj sayacı (istemci taraflı)
        var levelProgress: Double = 0 // güncel seviyenin ne kadarı tamamlandı (0...1), bkz. RelationshipXP
        /// Sohbetin GERÇEKTE hangi dilde geçtiğine dair son tahmin ("tr"/"en") —
        /// bildirim içeriği (JealousyContent vb.) bunu kullanır. Bkz. ConversationLanguage.
        var detectedLanguage: String?
        /// Bu (kullanıcı, karakter) sohbetine özel günlük rutin — bkz.
        /// CharacterSchedule, ChatViewModel.ensureScheduleGenerated. Eski
        /// kayıtlarda yok, `nil` olarak decode edilir.
        var schedule: CharacterSchedule?

        enum CodingKeys: String, CodingKey {
            case messages, xp, level, summary, summarizedCount, msgCounter, levelProgress, detectedLanguage, schedule
        }

        init(
            messages: [Message], xp: Int, level: Int, summary: String, summarizedCount: Int,
            msgCounter: Int = 0, levelProgress: Double = 0, detectedLanguage: String? = nil,
            schedule: CharacterSchedule? = nil
        ) {
            self.messages = messages
            self.xp = xp
            self.level = level
            self.summary = summary
            self.summarizedCount = summarizedCount
            self.msgCounter = msgCounter
            self.levelProgress = levelProgress
            self.detectedLanguage = detectedLanguage
            self.schedule = schedule
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            messages = try c.decode([Message].self, forKey: .messages)
            xp = try c.decode(Int.self, forKey: .xp)
            level = try c.decode(Int.self, forKey: .level)
            summary = try c.decode(String.self, forKey: .summary)
            summarizedCount = try c.decode(Int.self, forKey: .summarizedCount)
            // Eski kayıtlarda yok — 0'dan başlar (küçük bir kozmetik sıfırlama, sorun değil).
            msgCounter = (try? c.decode(Int.self, forKey: .msgCounter)) ?? 0
            levelProgress = (try? c.decode(Double.self, forKey: .levelProgress)) ?? 0
            detectedLanguage = try? c.decode(String.self, forKey: .detectedLanguage)
            schedule = try? c.decodeIfPresent(CharacterSchedule.self, forKey: .schedule)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(messages, forKey: .messages)
            try c.encode(xp, forKey: .xp)
            try c.encode(level, forKey: .level)
            try c.encode(summary, forKey: .summary)
            try c.encode(summarizedCount, forKey: .summarizedCount)
            try c.encode(msgCounter, forKey: .msgCounter)
            try c.encode(levelProgress, forKey: .levelProgress)
            try c.encodeIfPresent(detectedLanguage, forKey: .detectedLanguage)
            try c.encodeIfPresent(schedule, forKey: .schedule)
        }
    }
```

Replace it with:

```swift
    struct Stored: Codable {
        var messages: [Message]       // tüm gerçek mesajlar (görüntüleme için)
        var xp: Int                   // eski mutlak XP alanı — artık kullanılmıyor, geriye dönük uyum için duruyor
        var level: Int
        var summary: String           // özetlenmiş eski mesajlar
        var summarizedCount: Int      // kaç mesaj özetlendi
        var msgCounter: Int = 0       // terfi eşiği için mesaj sayacı (istemci taraflı)
        var levelProgress: Double = 0 // güncel seviyenin ne kadarı tamamlandı (0...1), bkz. RelationshipXP
        /// Sohbetin GERÇEKTE hangi dilde geçtiğine dair son tahmin ("tr"/"en") —
        /// bildirim içeriği (JealousyContent vb.) bunu kullanır. Bkz. ConversationLanguage.
        var detectedLanguage: String?
        /// Bu (kullanıcı, karakter) sohbetine özel günlük rutin — bkz.
        /// CharacterSchedule, ChatViewModel.ensureScheduleGenerated. Eski
        /// kayıtlarda yok, `nil` olarak decode edilir.
        var schedule: CharacterSchedule?
        /// Karakter uykudayken mesaj alıp uyandırıldıysa o anın zamanı — bkz.
        /// CharacterSleepState, ChatViewModel.handleWakeUpIfAsleep. `nil` =
        /// uyandırma geçersiz (normal programa göre uyanık ya da hâlâ uyuyor).
        var wokenUpAt: Date?
        /// Kullanıcı gerçek yatma saatine yakınken uyumasını istedi ve karakter
        /// kabul etti — bkz. chat/index.ts wentToSleep. `nil` = erken-uyuma
        /// geçersiz.
        var manualSleepAt: Date?

        enum CodingKeys: String, CodingKey {
            case messages, xp, level, summary, summarizedCount, msgCounter, levelProgress,
                 detectedLanguage, schedule, wokenUpAt, manualSleepAt
        }

        init(
            messages: [Message], xp: Int, level: Int, summary: String, summarizedCount: Int,
            msgCounter: Int = 0, levelProgress: Double = 0, detectedLanguage: String? = nil,
            schedule: CharacterSchedule? = nil, wokenUpAt: Date? = nil, manualSleepAt: Date? = nil
        ) {
            self.messages = messages
            self.xp = xp
            self.level = level
            self.summary = summary
            self.summarizedCount = summarizedCount
            self.msgCounter = msgCounter
            self.levelProgress = levelProgress
            self.detectedLanguage = detectedLanguage
            self.schedule = schedule
            self.wokenUpAt = wokenUpAt
            self.manualSleepAt = manualSleepAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            messages = try c.decode([Message].self, forKey: .messages)
            xp = try c.decode(Int.self, forKey: .xp)
            level = try c.decode(Int.self, forKey: .level)
            summary = try c.decode(String.self, forKey: .summary)
            summarizedCount = try c.decode(Int.self, forKey: .summarizedCount)
            // Eski kayıtlarda yok — 0'dan başlar (küçük bir kozmetik sıfırlama, sorun değil).
            msgCounter = (try? c.decode(Int.self, forKey: .msgCounter)) ?? 0
            levelProgress = (try? c.decode(Double.self, forKey: .levelProgress)) ?? 0
            detectedLanguage = try? c.decode(String.self, forKey: .detectedLanguage)
            schedule = try? c.decodeIfPresent(CharacterSchedule.self, forKey: .schedule)
            wokenUpAt = try? c.decodeIfPresent(Date.self, forKey: .wokenUpAt)
            manualSleepAt = try? c.decodeIfPresent(Date.self, forKey: .manualSleepAt)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(messages, forKey: .messages)
            try c.encode(xp, forKey: .xp)
            try c.encode(level, forKey: .level)
            try c.encode(summary, forKey: .summary)
            try c.encode(summarizedCount, forKey: .summarizedCount)
            try c.encode(msgCounter, forKey: .msgCounter)
            try c.encode(levelProgress, forKey: .levelProgress)
            try c.encodeIfPresent(detectedLanguage, forKey: .detectedLanguage)
            try c.encodeIfPresent(schedule, forKey: .schedule)
            try c.encodeIfPresent(wokenUpAt, forKey: .wokenUpAt)
            try c.encodeIfPresent(manualSleepAt, forKey: .manualSleepAt)
        }
    }
```

- [ ] **Step 2: Manual read-through verification**

No test target / no Xcode in this environment (see Global Constraints). Confirm: both new
fields are `Date?` (optional), both added to `CodingKeys`, both given `= nil` defaults in
the manual `init`, both decoded with `try?`/`decodeIfPresent` (old on-disk JSON files
without these keys must decode successfully, exact same treatment `schedule` already got),
both encoded with `encodeIfPresent`.

- [ ] **Step 3: Commit**

```bash
git add aiGirlfriend/Services/LocalConversationStore.swift
git commit -m "$(cat <<'EOF'
feat: add wokenUpAt/manualSleepAt fields to LocalConversationStore.Stored

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `CharacterSleepState.isEffectivelyAsleep`

**Files:**
- Create: `aiGirlfriend/Services/CharacterSleepState.swift`

**Interfaces:**
- Consumes: `LocalConversationStore.Stored` (Task 1), `ScheduleLookup.currentBlock(schedule:date:calendar:)` (existing, `ScheduleLookup.swift:11-32`).
- Produces: `CharacterSleepState.isEffectivelyAsleep(stored: LocalConversationStore.Stored?, now: Date) -> Bool` — the single source of truth consumed by Task 4 (wake-flow) and Task 9 (notification gating for Jealousy/LevelUp).

- [ ] **Step 1: Create the file**

```swift
//
//  CharacterSleepState.swift
//  Tek doğru kaynak: bir karakter şu an GERÇEKTEN uyuyor mu — programa göre
//  mi, yoksa uyandırma/erken-uyuma override'ları mı geçerli. Bkz.
//  LocalConversationStore.Stored.wokenUpAt/manualSleepAt.
//

import Foundation

enum CharacterSleepState {
    static func isEffectivelyAsleep(stored: LocalConversationStore.Stored?, now: Date = Date()) -> Bool {
        guard let stored else { return false } // hiç konuşulmamış — program henüz alakasız
        if stored.wokenUpAt != nil { return false }       // şu an uyandırma override'ı aktif
        if stored.manualSleepAt != nil { return true }    // erken-uyuma override'ı aktif
        guard let schedule = stored.schedule,
              let block = ScheduleLookup.currentBlock(schedule: schedule, date: now) else { return false }
        return block.isSleep
    }
}
```

- [ ] **Step 2: Manual read-through verification**

Confirm `ScheduleLookup.currentBlock` (already exists) takes `schedule: CharacterSchedule,
date: Date, calendar: Calendar` with `date`/`calendar` defaulted — this call passes `date:`
positionally-matched by label, matching that signature exactly.

- [ ] **Step 3: Commit**

```bash
git add aiGirlfriend/Services/CharacterSleepState.swift
git commit -m "$(cat <<'EOF'
feat: add CharacterSleepState.isEffectivelyAsleep

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `ScheduleLookup.nextSleepBlockStart`

**Files:**
- Modify: `aiGirlfriend/Services/ScheduleLookup.swift`

**Interfaces:**
- Consumes: existing private `minutesFromHHmm(_:)` in the same file.
- Produces: `ScheduleLookup.nextSleepBlockStart(schedule:from:calendar:) -> Date?` — consumed
  by Task 8 (`rescheduleBedtime`).

- [ ] **Step 1: Add the function**

Find the end of `ScheduleLookup.swift` (the closing brace of the `private static func
minutesFromHHmm` and the enum):

```swift
enum ScheduleLookup {
    static func currentBlock(
        schedule: CharacterSchedule,
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> ScheduleBlock? {
        // ... unchanged ...
    }

    private static func minutesFromHHmm(_ s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
}
```

Add a new function right after `currentBlock`, before `minutesFromHHmm`:

```swift
    /// Karakterin GERÇEK programına göre bir sonraki uyku bloğunun başlangıç
    /// anı — bugün henüz gelmediyse bugün, geldiyse (ya da yoksa) ileriki
    /// günlere bakar (en fazla bir hafta ileri, sonsuz döngüye girmesin diye).
    /// Bkz. NotificationScheduler.rescheduleBedtime.
    static func nextSleepBlockStart(
        schedule: CharacterSchedule,
        from: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        for dayOffset in 0..<8 {
            guard let candidateDay = calendar.date(byAdding: .day, value: dayOffset, to: from) else { continue }
            let blocks = calendar.isDateInWeekend(candidateDay) ? schedule.weekend : schedule.weekday
            let starts: [Date] = blocks.compactMap { block -> Date? in
                guard block.isSleep, let startMinutes = minutesFromHHmm(block.start) else { return nil }
                return calendar.date(
                    bySettingHour: startMinutes / 60, minute: startMinutes % 60, second: 0, of: candidateDay
                )
            }.filter { $0 > from }
            if let earliest = starts.min() { return earliest }
        }
        return nil
    }
```

- [ ] **Step 2: Manual read-through verification**

Confirm `minutesFromHHmm` is called from within the same `enum ScheduleLookup` (its
`private` access level is file-scoped to the enum, both functions are members of the same
type, so this is a valid call). Confirm the `dayOffset` loop starts at `from`'s own day
(`dayOffset: 0`) so a same-day future sleep block is found before falling through to
tomorrow.

- [ ] **Step 3: Commit**

```bash
git add aiGirlfriend/Services/ScheduleLookup.swift
git commit -m "$(cat <<'EOF'
feat: add ScheduleLookup.nextSleepBlockStart

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `SleepyContent` dialogue table

**Files:**
- Create: `aiGirlfriend/Services/Notifications/SleepyContent.swift`

**Interfaces:**
- Produces: `SleepyContent.question(language: String) -> String`, `SleepyContent.goodbye(language: String) -> String` — consumed by Task 6 (`NotificationDelegate`).

- [ ] **Step 1: Create the file**

```swift
//
//  SleepyContent.swift
//  Idle-timeout "can we sleep?" / goodnight lines AND the daily real-bedtime
//  announcement (same goodbye text, reused — see NotificationScheduler
//  .rescheduleBedtime). Single line per stage, no role/vibe axis (matches
//  the exact phrasing requested — see docs/superpowers/specs/2026-07-05-
//  sleep-state-redesign-design.md). Follows RoleOnlyContent.swift's
//  ConversationLanguage (tr/en) pattern, NOT the Localizable.xcstrings UI
//  catalog — this is bot dialogue, not a UI string.
//

import Foundation

enum SleepyContent {
    private static let byLanguage: [String: (question: String, goodbye: String)] = [
        "en": (
            question: String(localized: "I want to sleep, if that's ok can we sleep?"),
            goodbye: String(localized: "I am sleeping, goodnight")
        ),
        "tr": (
            question: "Uyumak istiyorum, uygunsa uyuyabilir miyiz?",
            goodbye: "Uyuyorum, iyi geceler"
        ),
    ]

    static func question(language: String) -> String {
        (byLanguage[language] ?? byLanguage["en"]!).question
    }

    static func goodbye(language: String) -> String {
        (byLanguage[language] ?? byLanguage["en"]!).goodbye
    }
}
```

- [ ] **Step 2: Manual read-through verification**

Confirm `ConversationLanguage.supported` is exactly `["tr", "en"]` (checked against
`ConversationLanguage.swift:17`) — this dictionary's two keys cover every value
`ConversationLanguage.current(for:)`/`.resolve(...)` can ever return, so the `?? byLanguage["en"]!` fallback is unreachable in practice but kept as a defensive default (matches `LikedYouContent.opener`'s exact fallback style).

- [ ] **Step 3: Commit**

```bash
git add aiGirlfriend/Services/Notifications/SleepyContent.swift
git commit -m "$(cat <<'EOF'
feat: add SleepyContent dialogue table for sleep notifications

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `NotificationScheduler` — new kinds, shared one-shot helper, sleepy-goodnight pair

**Files:**
- Modify: `aiGirlfriend/Services/NotificationScheduler.swift`

**Interfaces:**
- Consumes: `LocalConversationStore.Stored` (Task 1), `Character` (existing model — `id: UUID`, `name: String`).
- Produces: `NotificationScheduler.scheduleSleepyGoodnight(for character: Character, from: Date)`, `NotificationScheduler.cancelSleepyGoodnight(for characterID: UUID)` — consumed by Task 7 (`ChatViewModel`). Also widens `NotificationKind` with `.sleepyQuestion`, `.sleepyGoodbye`, `.bedtime` — consumed by Task 6 (`SleepyContent` via `NotificationDelegate`) and Task 8.

- [ ] **Step 1: Widen `NotificationKind`**

Find:

```swift
enum NotificationKind: String {
    case liked, ghosted, jealousy, levelUp
}
```

Replace with:

```swift
enum NotificationKind: String {
    case liked, ghosted, jealousy, levelUp, sleepyQuestion, sleepyGoodbye, bedtime
}
```

- [ ] **Step 2: Add the shared one-shot scheduling helper**

Find the end of the `Level-Up Tease` section (right before `// MARK: - Tap-handling glue`):

```swift
    /// Called on app foreground — never let a level-up tease fire while the app is active.
    func cancelLevelUpTimers() {
        center.getPendingNotificationRequests { [weak self] requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix("notif.levelup.") }
            self?.center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    // MARK: - Tap-handling glue
```

Insert a new section between them:

```swift
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

    // MARK: - Tap-handling glue
```

- [ ] **Step 2: Manual read-through verification**

Confirm `Character` has `id: UUID` and `name: String` members (used throughout this file
already for the other four notification types, e.g. `character.name` at line 90). Confirm
`scheduleOneShot`'s `fireAt` parameter accepts an absolute `Date` and both call sites pass
one (`from.addingTimeInterval(...)` for the pair, an absolute `Date` from
`ScheduleLookup.nextSleepBlockStart` for bedtime in Task 8).

- [ ] **Step 3: Commit**

```bash
git add aiGirlfriend/Services/NotificationScheduler.swift
git commit -m "$(cat <<'EOF'
feat: add sleepyQuestion/sleepyGoodbye/bedtime notification kinds + shared one-shot helper

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `NotificationDelegate` — handle the 3 new kinds

**Files:**
- Modify: `aiGirlfriend/Services/NotificationDelegate.swift`

**Interfaces:**
- Consumes: `SleepyContent.question(language:)`/`.goodbye(language:)` (Task 4), `NotificationKind.sleepyQuestion`/`.sleepyGoodbye`/`.bedtime` (Task 5).

- [ ] **Step 1: Add the 3 new cases to the line-selection switch**

Find:

```swift
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
        }

        if let line {
            injectMessage(line, for: characterID)
        }
```

Replace with:

```swift
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
```

- [ ] **Step 2: Add the 3 new cases to the navigation switch**

Find:

```swift
        // Level-up dışındaki bot bildirimleri sadece ilgili sekmeye yönlendirir —
        // doğrudan o botun sohbetini açmaz. "Liked You" artık Beğeniler
        // sekmesine gider (bkz. LikedByStore/LikesView), diğerleri Sohbetler'e.
        switch kind {
        case .levelUp:
            store.pendingMeetRequest = MeetRequest(character: character, prefillText: "")
        case .liked:
            store.pendingTab = .likes
        case .ghosted, .jealousy:
            store.pendingTab = .chat
        }
```

Replace with:

```swift
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
```

- [ ] **Step 3: Manual read-through verification**

Confirm both `switch kind` statements are now exhaustive over all 7 `NotificationKind`
cases (Swift requires this at compile time — any missed case would be a build error, which
is the point of widening the enum first in Task 5). Confirm `injectMessage` (unchanged,
already bumps `store.conversationsVersion` per the earlier chat-list-ordering fix) is still
the single injection point for all dialogue-bearing kinds.

- [ ] **Step 4: Commit**

```bash
git add aiGirlfriend/Services/NotificationDelegate.swift
git commit -m "$(cat <<'EOF'
feat: handle sleepyQuestion/sleepyGoodbye/bedtime notification taps

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `ChatViewModel.handleWakeUpIfAsleep` rewrite

**Files:**
- Modify: `aiGirlfriend/ViewModels/ChatViewModel.swift:539-550`

**Interfaces:**
- Consumes: `CharacterSleepState.isEffectivelyAsleep(stored:now:)` (Task 2), `NotificationScheduler.shared.scheduleSleepyGoodnight(for:from:)`/`.cancelSleepyGoodnight(for:)` (Task 5).

- [ ] **Step 1: Rewrite the function**

Find:

```swift
    /// Karakter şu an "uyuyor" bloğundaysa, mesaj göndermeden hemen ÖNCE
    /// gerçekliği taklit eden özel bir gecikme akışı çalıştırır: 5sn hiçbir
    /// şey değişmez (hâlâ uyuyor), sonra durum "Az önce uyandı"ya güncellenir,
    /// 5sn daha beklenir, SONRA çağıran normal yazma-balonu akışına devam
    /// eder. `currentActivity` bu süre boyunca mutasyona uğradığı için,
    /// sunucuya gönderilen `currentActivity` bağlamı da otomatik olarak
    /// "az önce uyandı" olur (send*() fonksiyonları bunu bu adımdan SONRA okur).
    private func handleWakeUpIfAsleep() async {
        guard let schedule = LocalConversationStore.shared.load(for: character.id)?.schedule,
              let block = ScheduleLookup.currentBlock(schedule: schedule),
              block.isSleep else { return }

        try? await Task.sleep(nanoseconds: 5_000_000_000)
        currentActivity = (
            label: String(localized: "Just woke up"),
            detail: "just woke up from being asleep, still a little groggy, texting from bed"
        )
        try? await Task.sleep(nanoseconds: 5_000_000_000)
    }
```

Replace with:

```swift
    /// Karakter şu an efektif olarak uyuyorsa (bkz. CharacterSleepState) VE
    /// henüz uyandırılmadıysa, mesaj göndermeden hemen ÖNCE gerçekliği taklit
    /// eden özel bir gecikme akışı çalıştırır: 5sn hiçbir şey değişmez (hâlâ
    /// uyuyor), sonra durum "Az önce uyandı"ya güncellenir, 5sn daha beklenir,
    /// SONRA `wokenUpAt` KALICI olarak kaydedilir (bkz. LocalConversationStore
    /// .Stored) — bir daha bu sohbet açık kaldığı sürece bu gecikme TEKRAR
    /// ÇALIŞMAZ ("konuşma devam ettiği sürece uyanık kal"). Zaten uyandırılmışsa
    /// (wokenUpAt != nil) gecikme tamamen atlanır. Her iki durumda da, uyanıkken
    /// gönderilen her mesaj uyku-öncesi zamanlayıcıyı sıfırlar (bkz.
    /// NotificationScheduler.scheduleSleepyGoodnight).
    private func handleWakeUpIfAsleep() async {
        let stored = LocalConversationStore.shared.load(for: character.id)
        guard CharacterSleepState.isEffectivelyAsleep(stored: stored) else { return }

        if stored?.wokenUpAt == nil {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            currentActivity = (
                label: String(localized: "Just woke up"),
                detail: "just woke up from being asleep, still a little groggy, texting from bed"
            )
            try? await Task.sleep(nanoseconds: 5_000_000_000)

            guard var updated = LocalConversationStore.shared.load(for: character.id) else { return }
            updated.wokenUpAt = Date()
            LocalConversationStore.shared.save(updated, for: character.id)
        }

        NotificationScheduler.shared.scheduleSleepyGoodnight(for: character, from: Date())
    }
```

- [ ] **Step 2: Manual read-through verification**

Confirm this function is still `private` and still called from the same three sites
(`send()`, `sendVoiceRequest()`, `sendImageRequest()` — unchanged, no call-site edits
needed). Confirm `LocalConversationStore.shared.load(for:)` is called twice here (once to
check state, once — inside the `if` — to get a fresh mutable copy to save); this matches
the existing `updateCache()` pattern elsewhere in this file of load-mutate-save.

- [ ] **Step 3: Commit**

```bash
git add aiGirlfriend/ViewModels/ChatViewModel.swift
git commit -m "$(cat <<'EOF'
fix: persist wake-up state instead of re-triggering the wake delay every message

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: `NotificationScheduler.rescheduleBedtime`

**Files:**
- Modify: `aiGirlfriend/Services/NotificationScheduler.swift`

**Interfaces:**
- Consumes: `ScheduleLookup.nextSleepBlockStart(schedule:from:calendar:)` (Task 3), `scheduleOneShot` (Task 5, private to this file).

- [ ] **Step 1: Add the function**

Find (right after the `Sleepy Goodnight` section added in Task 5, before `// MARK:
- Tap-handling glue`):

```swift
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
```

- [ ] **Step 2: Wire it into `onForeground`**

Find:

```swift
    func onForeground(characters: [Character]) {
        hasPermission { [weak self] granted in
            guard granted else { return }
            self?.cancelLevelUpTimers()
            self?.rescheduleLikedYou(characters: characters)
            self?.rescheduleGhosted(characters: characters)
            self?.armJealousyTimer(characters: characters)
        }
    }
```

Replace with:

```swift
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
```

- [ ] **Step 3: Manual read-through verification**

Confirm `LocalConversationStore.Stored.level: Int` (existing field) supports the `>= 5`
comparison directly. Confirm `ScheduleLookup.nextSleepBlockStart` (Task 3) is called with
its default `from: Date()`/`calendar: .current` (only `schedule:` passed explicitly here).

- [ ] **Step 4: Commit**

```bash
git add aiGirlfriend/Services/NotificationScheduler.swift
git commit -m "$(cat <<'EOF'
feat: add daily bedtime announcement for level>=5 characters

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Sleep-gating for the 4 existing notification triggers

**Files:**
- Modify: `aiGirlfriend/Services/NotificationScheduler.swift`

**Interfaces:**
- Consumes: `ScheduleLookup.currentBlock(schedule:date:calendar:)` (existing), `CharacterSleepState.isEffectivelyAsleep(stored:now:)` (Task 2).

- [ ] **Step 1: Ghosted — push a mid-sleep fire time forward to real wake time**

Find:

```swift
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
```

Replace with:

```swift
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

            var fireAt = lastMessage.createdAt.addingTimeInterval(Self.roleInterval(character.personalityRole))
            // Fire time could land mid-sleep hours (this offset can be up to 48h for
            // "distant") — push it to their real wake moment instead. Schedule-only
            // check (not CharacterSleepState) since this is a FUTURE timestamp, not
            // "right now" — wake/manual-sleep overrides can't be predicted that far out.
            if let schedule = stored.schedule,
               let block = ScheduleLookup.currentBlock(schedule: schedule, date: fireAt),
               block.isSleep {
                let endParts = block.end.split(separator: ":").compactMap { Int($0) }
                if endParts.count == 2,
                   let midnight = Calendar.current.date(bySettingHour: 0, minute: 0, second: 0, of: fireAt),
                   let wakeTimeToday = Calendar.current.date(bySettingHour: endParts[0], minute: endParts[1], second: 0, of: midnight) {
                    fireAt = wakeTimeToday > fireAt ? wakeTimeToday : wakeTimeToday.addingTimeInterval(86400)
                }
            }
            let interval = fireAt.timeIntervalSinceNow
            guard interval > 0 else {
                center.removePendingNotificationRequests(withIdentifiers: [Self.ghostedID(for: character.id)])
                continue
            }
```

- [ ] **Step 2: Jealousy — exclude characters currently asleep**

Find:

```swift
    func armJealousyTimer(characters: [Character]) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.jealousyID])
        let eligible = characters.filter { character in
            !BlockedCharactersStore.isBlocked(character.id) &&
            LocalConversationStore.shared.load(for: character.id) != nil &&
            NotificationPreferencesStore.canSendMore(for: character.id)
        }
```

Replace with:

```swift
    func armJealousyTimer(characters: [Character]) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.jealousyID])
        let eligible = characters.filter { character in
            let stored = LocalConversationStore.shared.load(for: character.id)
            return !BlockedCharactersStore.isBlocked(character.id) &&
                stored != nil &&
                NotificationPreferencesStore.canSendMore(for: character.id) &&
                !CharacterSleepState.isEffectivelyAsleep(stored: stored)
        }
```

- [ ] **Step 3: LevelUp — exclude characters currently asleep**

Find:

```swift
        let eligible = characters.filter { character in
            !BlockedCharactersStore.isBlocked(character.id) &&
            (LocalConversationStore.shared.load(for: character.id)?.levelProgress ?? 0) >= 0.8 &&
            NotificationPreferencesStore.canSendMore(for: character.id)
        }
        guard let character = eligible.randomElement() else { return }
```

Replace with:

```swift
        let eligible = characters.filter { character in
            let stored = LocalConversationStore.shared.load(for: character.id)
            return !BlockedCharactersStore.isBlocked(character.id) &&
                (stored?.levelProgress ?? 0) >= 0.8 &&
                NotificationPreferencesStore.canSendMore(for: character.id) &&
                !CharacterSleepState.isEffectivelyAsleep(stored: stored)
        }
        guard let character = eligible.randomElement() else { return }
```

- [ ] **Step 4: Manual read-through verification**

Ghosted's fix is the most involved one — re-read it against the intent: "if the computed
`fireAt`'s time-of-day falls inside a sleep block, push it to that block's end time." The
code does exactly that: parses `block.end`'s `HH:mm` into `endParts`, builds that time on
`fireAt`'s own calendar day (`wakeTimeToday`), and if that computed wake moment is still
`<=` `fireAt` (meaning the block wraps past midnight, e.g. a 23:00-07:00 block where
`fireAt` itself is at 2am — the "07:00 today" would be BEFORE `fireAt`), adds a day so the
wake time actually lands in the future. Confirm `CharacterSleepState.isEffectivelyAsleep(stored:)` uses the default
`now: Date()` in both Jealousy and LevelUp (correct — these two only care about "right now"
given their tiny 2-10min/60s fire windows, per the spec).

- [ ] **Step 5: Commit**

```bash
git add aiGirlfriend/Services/NotificationScheduler.swift
git commit -m "$(cat <<'EOF'
fix: gate Ghosted/Jealousy/LevelUp notifications against sleep state

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: LikedYou — randomize the fire hour, gate against that hour's sleep state

**Files:**
- Modify: `aiGirlfriend/Services/NotificationScheduler.swift`

**Interfaces:**
- Consumes: `ScheduleLookup.currentBlock(schedule:date:calendar:)`.

- [ ] **Step 1: Randomize the hour and exclude bots asleep at that hour**

Find:

```swift
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
```

Replace with:

```swift
    func rescheduleLikedYou(characters: [Character]) {
        guard !LikedByStore.hasPickedToday() else { return }
        center.removePendingNotificationRequests(withIdentifiers: [Self.likedYouIDPrefix + "0"])
        let alreadyLiked = LikedByStore.likedCharacterIDs()
        let hour = Int.random(in: 9...22)
        let eligible = characters.filter { character in
            guard character.createdBy == nil,
                  LocalConversationStore.shared.load(for: character.id) == nil,
                  !alreadyLiked.contains(character.id)
            else { return false }
            // Untalked bots have no LocalConversationStore entry, so no schedule
            // either — nothing to check here in practice today, but if a future
            // change ever attaches a schedule to untalked catalog bots, this stays
            // correct rather than silently ignoring it.
            if let schedule = LocalConversationStore.shared.load(for: character.id)?.schedule,
               let block = ScheduleLookup.currentBlock(schedule: schedule, date: Calendar.current.date(
                   bySettingHour: hour, minute: 0, second: 0, of: Date()
               ) ?? Date()),
               block.isSleep {
                return false
            }
            return true
        }
        guard let bot = eligible.randomElement() else { return }
        LikedByStore.recordLike(bot.id)
        scheduleLikedYou(bot: bot, slotIndex: 0, hour: hour)
    }
```

- [ ] **Step 2: Manual read-through verification**

Confirm `scheduleLikedYou(bot:slotIndex:hour:)` (unchanged, already exists) takes an `hour:
Int` and builds a `UNCalendarNotificationTrigger(dateMatching:)` from it — the randomized
`hour` from `Int.random(in: 9...22)` passes straight through, no other change needed there.
Note the schedule check here is effectively a no-op today (untalked bots never have a
`schedule`, per the same-line comment) but costs nothing and future-proofs the function.

- [ ] **Step 3: Commit**

```bash
git add aiGirlfriend/Services/NotificationScheduler.swift
git commit -m "$(cat <<'EOF'
feat: randomize LikedYou fire hour instead of fixed 13:00

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: `chat/index.ts` — `nearSleepTime`, sleep-decline rule, `wentToSleep` classifier

**Files:**
- Modify: `supabase/functions/chat/index.ts`

**Interfaces:**
- Consumes: existing `callGrok(messages, maxTokens, convId?)`, existing `personalityRole`/`currentLevel`/`turnContext`/`conversationId` locals.
- Produces: response field `wentToSleep: boolean` (clientHistory-mode JSON) — consumed by Task 12 (`ChatService`/`ChatViewModel`). Request field `nearSleepTime: boolean` — consumed the other direction, sent by Task 12.

- [ ] **Step 1: Add the `SLEEP_RULE` constant**

Find `PHOTO_DOWNLOAD_REACTION_RULE`'s closing line (`chat/index.ts`, right before the
`Belirli kalıp cümleleri yasaklamak...` comment above `VARIATION_RULE`):

```typescript
const PHOTO_DOWNLOAD_REACTION_RULE =
  "\n\n[PHOTO DOWNLOAD REACTION] The user just downloaded a private/intimate " +
  "photo of you to their own device. Write ONE short, natural, in-character " +
  "reaction to this — a cute, genuine complaint or tease about it (e.g. " +
  "concern about it being shared, playful mock-offense, flustered teasing) — " +
  "whatever actually fits your personality and how close you are with the " +
  "user right now. Reason this out yourself in the moment; never reuse a " +
  "fixed template line, and never sound robotic or like a canned response. " +
  "Output ONLY the reaction line itself, nothing else.";

// Belirli kalıp cümleleri yasaklamak (blocklist) işe yaramıyor
```

Insert between them:

```typescript
const PHOTO_DOWNLOAD_REACTION_RULE =
  "\n\n[PHOTO DOWNLOAD REACTION] The user just downloaded a private/intimate " +
  "photo of you to their own device. Write ONE short, natural, in-character " +
  "reaction to this — a cute, genuine complaint or tease about it (e.g. " +
  "concern about it being shared, playful mock-offense, flustered teasing) — " +
  "whatever actually fits your personality and how close you are with the " +
  "user right now. Reason this out yourself in the moment; never reuse a " +
  "fixed template line, and never sound robotic or like a canned response. " +
  "Output ONLY the reaction line itself, nothing else.";

// Level/role are stable per-character (safe in the static system prompt, same
// treatment as humorDirective) — the actual near-bedtime BOOLEAN goes in
// turnContext instead (it changes constantly as bedtime approaches, and
// anything that changes every turn must stay OUT of the system prompt or it
// breaks xAI's prompt-caching prefix-match — see turnContext below).
function sleepRule(role: string, level: number): string {
  return (
    "\n\n[SLEEP REQUEST] Each of your turns includes a [BEDTIME PROXIMITY] " +
    "note telling you whether it's currently close to (or within) your real " +
    "scheduled sleep time. If the user asks you to go to sleep or says " +
    "goodnight and wants you to sleep: agree naturally and say goodnight " +
    "ONLY if that note says it's close to your bedtime. If it is NOT close " +
    `to your bedtime, decline — but decline in whatever way actually fits ` +
    `YOUR personality (role: ${role}, relationship level ${level}/10) and ` +
    "the vibe already established in your character description above. " +
    "There is no fixed tone for this — reason it out per your own character " +
    "(a shy/low-level character declines very differently than a confident/ " +
    "high-level one). Never mention the words 'schedule' or 'bedtime note' " +
    "explicitly, just act on it naturally."
  );
}

// Belirli kalıp cümleleri yasaklamak (blocklist) işe yaramıyor
```

- [ ] **Step 2: Add the `wentToSleep` classifier function**

Find `callGrok`'s closing brace (right before `Deno.serve(async (req: Request) => {`):

```typescript
async function callGrok(messages: WireMessage[], maxTokens: number, convId?: string): Promise<string> {
  // ... unchanged ...
}

Deno.serve(async (req: Request) => {
```

Insert between them:

```typescript
async function callGrok(messages: WireMessage[], maxTokens: number, convId?: string): Promise<string> {
  // ... unchanged ...
}

// Confirms whether a reply ACTUALLY agreed to go to sleep (not just discussed
// the topic) — only called when nearSleepTime was true, same pattern as
// chat-image/index.ts's classifyPrivacy.
async function classifySleepAgreement(userMessage: string, reply: string): Promise<boolean> {
  const raw = await callGrok(
    [
      {
        role: "system",
        content:
          "You are a classifier. Given a short exchange between a user and " +
          "an AI character, answer with exactly one word: YES if the " +
          "character's reply agreed to go to sleep / said goodnight for the " +
          "night, NO if it did not (e.g. declined, changed the subject, or " +
          "the exchange wasn't about sleeping at all). Answer with only YES " +
          "or NO, nothing else.",
      },
      { role: "user", content: `User: ${userMessage}\nCharacter: ${reply}` },
    ],
    5
  );
  return raw.trim().toUpperCase().startsWith("Y");
}

Deno.serve(async (req: Request) => {
```

- [ ] **Step 3: Parse `nearSleepTime` from the request body**

Find:

```typescript
    // Fotoğraf isteği tepki modu mu? (bkz. IMAGE_CAPTION_RULE)
    const imageReactionChat: boolean = body.imageReactionChat === true;
```

Replace with:

```typescript
    // Fotoğraf isteği tepki modu mu? (bkz. IMAGE_CAPTION_RULE)
    const imageReactionChat: boolean = body.imageReactionChat === true;
    // İstemci ScheduleLookup ile hesaplar — gerçek yatma saatine 1 saatten
    // yakın mı (ya da içindeyse) (bkz. sleepRule, chat-index turnContext).
    const nearSleepTime: boolean = body.nearSleepTime === true;
```

- [ ] **Step 4: Append `sleepRule` to the static system prompt, and the dynamic bedtime-proximity note to `turnContext`**

Find:

```typescript
    // Sadece DÜZ metin turlarında — voiceChat/imageReactionChat zaten düğme
    // akışının kendisi, o turlarda bu uyarı anlamsız/çelişkili olurdu.
    if (!voiceChat && !imageReactionChat) {
      system += MEDIA_REQUEST_RULE;
    }
    if (!useClientHistory && convo.summary && convo.summary.trim() !== "") {
      system += `\n\n[Önceki konuşmalarınızın özeti]\n${stripVoiceTags(convo.summary)}`;
    }
```

Replace with:

```typescript
    // Sadece DÜZ metin turlarında — voiceChat/imageReactionChat zaten düğme
    // akışının kendisi, o turlarda bu uyarı anlamsız/çelişkili olurdu.
    if (!voiceChat && !imageReactionChat) {
      system += MEDIA_REQUEST_RULE;
      system += sleepRule(personalityRole, currentLevel);
    }
    if (!useClientHistory && convo.summary && convo.summary.trim() !== "") {
      system += `\n\n[Önceki konuşmalarınızın özeti]\n${stripVoiceTags(convo.summary)}`;
    }
```

Find:

```typescript
    let turnContext = timeContext(lastMessageAt, clientNow, tzOffsetMinutes);
    if (currentActivity) {
      turnContext += `\n\n[GÜNLÜK RUTİN] Şu anda: ${currentActivity}. Ton ve ` +
        `müsaitliğini buna doğal şekilde yansıt (ör. işteyken kısa/dikkati ` +
        `dağınık, evde rahatken daha uzun sohbet edebilirsin) ama bunu her ` +
        `mesajda birebir tekrarlama.`;
    }
```

Replace with:

```typescript
    let turnContext = timeContext(lastMessageAt, clientNow, tzOffsetMinutes);
    if (currentActivity) {
      turnContext += `\n\n[GÜNLÜK RUTİN] Şu anda: ${currentActivity}. Ton ve ` +
        `müsaitliğini buna doğal şekilde yansıt (ör. işteyken kısa/dikkati ` +
        `dağınık, evde rahatken daha uzun sohbet edebilirsin) ama bunu her ` +
        `mesajda birebir tekrarlama.`;
    }
    if (!voiceChat && !imageReactionChat) {
      turnContext += nearSleepTime
        ? "\n\n[BEDTIME PROXIMITY] It is currently close to or within your real scheduled sleep time."
        : "\n\n[BEDTIME PROXIMITY] It is NOT close to your real scheduled sleep time right now.";
    }
```

- [ ] **Step 5: Run the classifier after the reply and include `wentToSleep` in the response**

Find:

```typescript
    const reply = await callGrok(grokMessages, 600, conversationId);

    // 4) Mesajları kaydet — clientHistory modunda istemci kendi saklıyor, DB'ye yazma
```

Replace with:

```typescript
    const reply = await callGrok(grokMessages, 600, conversationId);
    const wentToSleep = (!voiceChat && !imageReactionChat && nearSleepTime)
      ? await classifySleepAgreement(userMessage!, reply)
      : false;

    // 4) Mesajları kaydet — clientHistory modunda istemci kendi saklıyor, DB'ye yazma
```

Find:

```typescript
    // 5) Özetleme — sadece DB modunda (clientHistory modunda istemci geçmişi yönetiyor)
    if (useClientHistory) {
      return json({ conversationId, reply, level: newLevel });
    }
```

Replace with:

```typescript
    // 5) Özetleme — sadece DB modunda (clientHistory modunda istemci geçmişi yönetiyor)
    if (useClientHistory) {
      return json({ conversationId, reply, level: newLevel, wentToSleep });
    }
```

- [ ] **Step 6: Deploy**

```bash
cd /Users/furkanozsoy/Desktop/Projects/aigf/WECAN
SUPABASE_ACCESS_TOKEN=<paste the PAT from project memory here, do not commit it> npx supabase functions deploy chat --project-ref ohpvhgwjmrfjclnumgnm --no-verify-jwt
```

Expected: `{"project_ref":"ohpvhgwjmrfjclnumgnm","functions":["chat"],...,"message":"Deployed Functions."}`

- [ ] **Step 7: Verify — near bedtime, agree; not near bedtime, decline in-character**

```bash
JWT=$(curl -s -X POST "https://ohpvhgwjmrfjclnumgnm.supabase.co/auth/v1/signup" \
  -H "apikey: sb_publishable_AdvrSU0EhHDJyWsOtGGhZg_DHca3OaB" \
  -H "Content-Type: application/json" -d '{}' | python3 -c "import json,sys;print(json.load(sys.stdin)['access_token'])")

echo "=== nearSleepTime: true (expect agreement + wentToSleep: true) ==="
curl -s -X POST "https://ohpvhgwjmrfjclnumgnm.supabase.co/functions/v1/chat" \
  -H "apikey: sb_publishable_AdvrSU0EhHDJyWsOtGGhZg_DHca3OaB" -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"characterId":"00000000-0000-0000-0000-000000000002","systemPrompt":"","clientHistory":[],"localSummary":"","level":1,"userMessage":"I think you should go to sleep now, goodnight","nearSleepTime":true}'

echo "=== nearSleepTime: false (expect in-character decline + wentToSleep: false) ==="
curl -s -X POST "https://ohpvhgwjmrfjclnumgnm.supabase.co/functions/v1/chat" \
  -H "apikey: sb_publishable_AdvrSU0EhHDJyWsOtGGhZg_DHca3OaB" -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"characterId":"00000000-0000-0000-0000-000000000002","systemPrompt":"","clientHistory":[],"localSummary":"","level":1,"userMessage":"I think you should go to sleep now, goodnight","nearSleepTime":false}'
```

Expected: first call's `reply` sounds like a natural goodnight, `"wentToSleep":true`.
Second call's `reply` declines in-character (not a fixed "sassy" line — should read as
whatever fits a level-1 flirty-role character), `"wentToSleep":false`.

- [ ] **Step 8: Commit**

```bash
git add supabase/functions/chat/index.ts
git commit -m "$(cat <<'EOF'
feat: natural in-chat sleep-agreement — nearSleepTime signal, personality-driven decline, wentToSleep classifier

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: Client wiring — `nearSleepTime` request field, `wentToSleep` response handling

**Files:**
- Modify: `aiGirlfriend/Services/ChatService.swift`
- Modify: `aiGirlfriend/ViewModels/ChatViewModel.swift`

**Interfaces:**
- Consumes: Task 11's `nearSleepTime` request field / `wentToSleep` response field. `ScheduleLookup.currentBlock`/`nextSleepBlockStart` (existing/Task 3). `NotificationScheduler.shared.cancelSleepyGoodnight(for:)` (Task 5).
- Produces: `ChatReply.wentToSleep: Bool` — consumed by `ChatViewModel.send()`.

- [ ] **Step 1: Add `nearSleepTime` to `ChatRequest` and `wentToSleep` to `ChatResponse`/`ChatReply`**

In `aiGirlfriend/Services/ChatService.swift`, find:

```swift
    let photoDownloadReaction: Bool?
    let photoURL: String?
}
```

Replace with:

```swift
    let photoDownloadReaction: Bool?
    let photoURL: String?
    /// İstemci ScheduleLookup ile hesaplar — gerçek yatma saatine 1 saatten
    /// yakın mı (bkz. ChatViewModel.send, chat/index.ts sleepRule).
    let nearSleepTime: Bool?
}
```

Find:

```swift
private struct ChatResponse: Codable {
    let conversationId: String?
    let reply: String?
    let history: [WireMessage]?
    let xp: Int?
    let level: Int?
    let leveledUp: Bool?
    let photoUrl: String?
    let summary: String?   // özetleme modunda döner
    let schedule: CharacterSchedule?   // özetleme modunda döner (rafine edilmiş rutin)
}
```

Replace with:

```swift
private struct ChatResponse: Codable {
    let conversationId: String?
    let reply: String?
    let history: [WireMessage]?
    let xp: Int?
    let level: Int?
    let leveledUp: Bool?
    let photoUrl: String?
    let summary: String?   // özetleme modunda döner
    let schedule: CharacterSchedule?   // özetleme modunda döner (rafine edilmiş rutin)
    let wentToSleep: Bool?
}
```

Find:

```swift
struct ChatReply {
    let reply: String
    let level: Int      // sunucunun sakladığı (istemcinin bir önceki turda gönderdiği) seviye
    let photoURL: URL?
}
```

Replace with:

```swift
struct ChatReply {
    let reply: String
    let level: Int      // sunucunun sakladığı (istemcinin bir önceki turda gönderdiği) seviye
    let photoURL: URL?
    /// true ise karakter bu turda gerçekten uyumayı kabul etti (bkz.
    /// ChatViewModel.send, chat/index.ts classifySleepAgreement).
    let wentToSleep: Bool
}
```

- [ ] **Step 2: Add `nearSleepTime` parameter to `sendWithLocalHistory`, thread it through `perform`/`ChatRequest`, populate `wentToSleep` on both `ChatReply` construction sites**

Find:

```swift
    func send(character: Character, userMessage: String, level: Int, lastMessageAt: Date? = nil) async throws -> ChatReply {
        let resp = try await call(character: character, userMessage: userMessage, level: level, lastMessageAt: lastMessageAt)
        return ChatReply(
            reply: resp.reply ?? "",
            level: resp.level ?? level,
            photoURL: resp.photoUrl.flatMap(URL.init(string:))
        )
    }
```

Replace with:

```swift
    func send(character: Character, userMessage: String, level: Int, lastMessageAt: Date? = nil) async throws -> ChatReply {
        let resp = try await call(character: character, userMessage: userMessage, level: level, lastMessageAt: lastMessageAt)
        return ChatReply(
            reply: resp.reply ?? "",
            level: resp.level ?? level,
            photoURL: resp.photoUrl.flatMap(URL.init(string:)),
            wentToSleep: resp.wentToSleep ?? false
        )
    }
```

Find:

```swift
    func sendWithLocalHistory(
        character: Character,
        localMessages: [Message],
        summary: String,
        userMessage: String,
        level: Int,
        lastMessageAt: Date? = nil,
        voiceChat: Bool = false,
        imageReactionChat: Bool = false,
        currentActivity: String? = nil
    ) async throws -> ChatReply {
        let wireHistory = localMessages
            .filter { $0.imageURL == nil }
            .suffix(20)
            .map { WireHistoryMessage(role: $0.role.rawValue, content: $0.content) }
        let resp = try await perform(
            character: character,
            userMessage: userMessage,
            extra: .localHistory(wireHistory, summary: summary.isEmpty ? nil : summary),
            level: level,
            lastMessageAt: lastMessageAt,
            voiceChat: voiceChat,
            imageReactionChat: imageReactionChat,
            currentActivity: currentActivity
        )
        return ChatReply(
            reply: resp.reply ?? "",
            level: resp.level ?? level,
            photoURL: resp.photoUrl.flatMap(URL.init(string:))
        )
    }
```

Replace with:

```swift
    func sendWithLocalHistory(
        character: Character,
        localMessages: [Message],
        summary: String,
        userMessage: String,
        level: Int,
        lastMessageAt: Date? = nil,
        voiceChat: Bool = false,
        imageReactionChat: Bool = false,
        currentActivity: String? = nil,
        nearSleepTime: Bool = false
    ) async throws -> ChatReply {
        let wireHistory = localMessages
            .filter { $0.imageURL == nil }
            .suffix(20)
            .map { WireHistoryMessage(role: $0.role.rawValue, content: $0.content) }
        let resp = try await perform(
            character: character,
            userMessage: userMessage,
            extra: .localHistory(wireHistory, summary: summary.isEmpty ? nil : summary),
            level: level,
            lastMessageAt: lastMessageAt,
            voiceChat: voiceChat,
            imageReactionChat: imageReactionChat,
            currentActivity: currentActivity,
            nearSleepTime: nearSleepTime
        )
        return ChatReply(
            reply: resp.reply ?? "",
            level: resp.level ?? level,
            photoURL: resp.photoUrl.flatMap(URL.init(string:)),
            wentToSleep: resp.wentToSleep ?? false
        )
    }
```

Find `perform`'s signature and `ChatRequest(...)` construction:

```swift
    private func perform(
        character: Character,
        userMessage: String?,
        extra: RequestExtra = .none,
        level: Int? = nil,
        lastMessageAt: Date? = nil,
        voiceChat: Bool = false,
        imageReactionChat: Bool = false,
        currentActivity: String? = nil,
        previousSchedule: CharacterSchedule? = nil
    ) async throws -> ChatResponse {
```

Replace with:

```swift
    private func perform(
        character: Character,
        userMessage: String?,
        extra: RequestExtra = .none,
        level: Int? = nil,
        lastMessageAt: Date? = nil,
        voiceChat: Bool = false,
        imageReactionChat: Bool = false,
        currentActivity: String? = nil,
        previousSchedule: CharacterSchedule? = nil,
        nearSleepTime: Bool = false
    ) async throws -> ChatResponse {
```

Find:

```swift
            currentActivity: currentActivity,
            previousSchedule: previousSchedule,
            photoDownloadReaction: photoDownloadReaction,
            photoURL: photoURL
        )
        request.httpBody = try JSONEncoder().encode(body)
```

Replace with:

```swift
            currentActivity: currentActivity,
            previousSchedule: previousSchedule,
            photoDownloadReaction: photoDownloadReaction,
            photoURL: photoURL,
            nearSleepTime: nearSleepTime
        )
        request.httpBody = try JSONEncoder().encode(body)
```

- [ ] **Step 3: `ChatViewModel.send()` — compute `nearSleepTime`, pass it, handle `wentToSleep`**

Find:

```swift
            do {
                let stored = LocalConversationStore.shared.load(for: character.id)
                let realMsgs = realMessages()
                let result = try await service.sendWithLocalHistory(
                    character: character,
                    localMessages: realMsgs,
                    summary: stored?.summary ?? "",
                    userMessage: text,
                    level: relationshipLevel,
                    lastMessageAt: lastMessageAt,
                    currentActivity: currentActivity?.detail
                )
```

Replace with:

```swift
            do {
                let stored = LocalConversationStore.shared.load(for: character.id)
                let realMsgs = realMessages()
                let result = try await service.sendWithLocalHistory(
                    character: character,
                    localMessages: realMsgs,
                    summary: stored?.summary ?? "",
                    userMessage: text,
                    level: relationshipLevel,
                    lastMessageAt: lastMessageAt,
                    currentActivity: currentActivity?.detail,
                    nearSleepTime: isNearSleepTime()
                )
```

Find (right after `applyPostReplyEffects(gotPhoto: nil, stored: stored)` inside `send()`):

```swift
                messages.append(Message(role: .assistant, content: result.reply))

                applyPostReplyEffects(gotPhoto: nil, stored: stored)
            } catch {
                errorMessage = error.localizedDescription
                showsTypingBubble = false
                store?.setTyping(character.id, false)
            }
            isSending = false
        }
    }
```

Replace with:

```swift
                messages.append(Message(role: .assistant, content: result.reply))

                applyPostReplyEffects(gotPhoto: nil, stored: stored)

                if result.wentToSleep {
                    var updated = LocalConversationStore.shared.load(for: character.id) ?? stored
                    updated?.manualSleepAt = Date()
                    updated?.wokenUpAt = nil
                    if let updated { LocalConversationStore.shared.save(updated, for: character.id) }
                    NotificationScheduler.shared.cancelSleepyGoodnight(for: character.id)
                }
            } catch {
                errorMessage = error.localizedDescription
                showsTypingBubble = false
                store?.setTyping(character.id, false)
            }
            isSending = false
        }
    }

    /// Gerçek yatma saatine 1 saatten yakın mı (ya da içinde miyiz) — bkz.
    /// chat/index.ts sleepRule/turnContext. Yerel hesaplanır, ağ çağrısı yok.
    private func isNearSleepTime() -> Bool {
        guard let schedule = LocalConversationStore.shared.load(for: character.id)?.schedule else { return false }
        let now = Date()
        if ScheduleLookup.currentBlock(schedule: schedule, date: now)?.isSleep == true { return true }
        guard let nextStart = ScheduleLookup.nextSleepBlockStart(schedule: schedule, from: now) else { return false }
        return nextStart.timeIntervalSince(now) <= 3600
    }
```

- [ ] **Step 4: Manual read-through verification**

Confirm every other call site of `sendWithLocalHistory` (`sendVoiceRequest()`,
`sendImageRequest()`) still compiles without change — the new `nearSleepTime` parameter has
a `= false` default, so those two call sites (which don't pass it) are unaffected, matching
the design decision that natural sleep-agreement only applies to the plain-text `send()`
path. Confirm `ChatReply`'s new `wentToSleep` field is non-optional (`Bool`, not `Bool?`) at
its two construction sites (`send`, `sendWithLocalHistory`) — both use `resp.wentToSleep ??
false`, so the non-optional type is always satisfiable. Confirm the `manualSleepAt`/
`wokenUpAt` update in `ChatViewModel.send()` uses `LocalConversationStore.shared.load(for:)
?? stored` — falling back to the already-loaded `stored` local only if a fresh load somehow
returns `nil` (shouldn't happen since it was just loaded earlier in the same function, but
avoids a force-unwrap).

- [ ] **Step 5: Commit**

```bash
git add aiGirlfriend/Services/ChatService.swift aiGirlfriend/ViewModels/ChatViewModel.swift
git commit -m "$(cat <<'EOF'
feat: wire nearSleepTime request + wentToSleep response into ChatViewModel.send

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Post-plan: still owed (cannot be done in this environment)

- Real Xcode build + on-device smoke test of every Swift task (no Xcode.app available here).
- Manual QA: message a sleeping character (confirm one wake delay, not one per message);
  leave a woken conversation idle 10min (confirm the "can we sleep?" question appears) then
  15min total with no reply (confirm the goodnight appears and the character reverts to
  asleep); ask a character to sleep near/at their real bedtime (confirm agreement +
  `manualSleepAt` persists) and far from it (confirm an in-character decline, not silence);
  wait for a level≥5 character's real bedtime with the app foregrounded recently (confirm
  the daily bedtime text arrives); confirm Ghosted/Jealousy/LevelUp never fire while a
  character is asleep, and LikedYou's fire hour actually varies day to day.
