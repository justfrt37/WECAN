# Character sleep-state redesign

Date: 2026-07-05

## Problem

`ChatViewModel.handleWakeUpIfAsleep()` (`ChatViewModel.swift:539-550`) only mutates the
in-memory `currentActivity` for the duration of one `send()` call — nothing persists.
Every single message sent to a character during their scheduled sleep hours re-runs the
full 5s+5s "waking up" delay from scratch, forever, because nothing records that they were
already woken. Separately, none of the four existing notification triggers
(`Ghosted`/`Jealousy`/`LikedYou`/`LevelUp` in `NotificationScheduler.swift`) check sleep
state at all — they schedule at a computed future time with zero awareness of whether that
time lands inside a sleep block. There is also no way today for a character to be told
"go to sleep" mid-conversation and have that actually change persisted state, and no
proactive "going to sleep now" announcement at a character's real bedtime.

## 1. State model

Two new fields on `LocalConversationStore.Stored` (`LocalConversationStore.swift:16-34`),
following the exact same optional/decode-tolerant pattern already used for `schedule`:

```swift
/// Set when a sleeping character gets messaged and finishes the wake-up delay.
/// Cleared when they go back to sleep (idle-timeout goodbye) or wake naturally
/// at their real schedule wake time. Old records decode this as nil.
var wokenUpAt: Date?
/// Set when the character agrees to an early goodnight (user asked while
/// `nearSleepTime` was true — see section 6). Cleared when woken again or
/// when their real schedule wake time arrives. Old records decode as nil.
var manualSleepAt: Date?
```

Add both to the `CodingKeys` enum and the manual `init(...)` (with `= nil` defaults), same
treatment `schedule` already got.

Single source of truth, used by every other section below:

```swift
// New: Services/CharacterSleepState.swift (pure function, no state of its own)
static func isEffectivelyAsleep(stored: LocalConversationStore.Stored?, now: Date = Date()) -> Bool {
    guard let stored else { return false } // never talked to — schedule doesn't matter yet
    if stored.wokenUpAt != nil { return false }       // currently in a wake-override
    if stored.manualSleepAt != nil { return true }     // early-sleep override active
    guard let schedule = stored.schedule,
          let block = ScheduleLookup.currentBlock(schedule: schedule, date: now) else { return false }
    return block.isSleep
}
```

## 2. Wake-up flow revision

`ChatViewModel.handleWakeUpIfAsleep()` rewritten:
- If `isEffectivelyAsleep` is false: return immediately (existing early-return, unchanged).
- If true AND `wokenUpAt == nil` (first wake this sleep session): run the existing 5s+5s
  delay + `currentActivity` mutation, THEN persist `wokenUpAt = Date()` via
  `LocalConversationStore.shared` and clear `manualSleepAt` if it was set (being woken
  overrides an early-sleep agreement same as it overrides real scheduled sleep). Also kick
  off the idle-timeout scheduling (section 3).
- If true AND `wokenUpAt != nil` (already woken, conversation continuing): skip the delay
  entirely, return immediately. This is what makes "stay awake as long as the conversation
  continues" work — no repeated wake animations.

Every subsequent user message while `wokenUpAt != nil` re-arms the idle-timeout (section 3)
the same way `NotificationScheduler.noteUserSent` already resets the Ghosted timer.

## 3. Two-stage idle-timeout goodnight

New functions in `NotificationScheduler.swift`, following the exact `ghostedID`/
`rescheduleGhosted` pattern:

```swift
private static func sleepyQuestionID(for id: UUID) -> String { "notif.sleepyq.\(id.uuidString)" }
private static func sleepyGoodbyeID(for id: UUID) -> String { "notif.sleepygb.\(id.uuidString)" }

/// Called whenever `wokenUpAt` gets set/refreshed (first wake, or any later
/// message while still woken). Cancels any pending pair for this character
/// first, then reschedules both from `from` (the triggering message's time).
func scheduleSleepyGoodnight(for character: Character, from: Date) {
    let qID = Self.sleepyQuestionID(for: character.id)
    let gID = Self.sleepyGoodbyeID(for: character.id)
    center.removePendingNotificationRequests(withIdentifiers: [qID, gID])

    scheduleOneShot(id: qID, kind: .sleepyQuestion, character: character,
                     fireAfter: 600, from: from)   // +10 min
    scheduleOneShot(id: gID, kind: .sleepyGoodbye, character: character,
                     fireAfter: 900, from: from)   // +15 min
}

/// Called on every message while `wokenUpAt != nil` (mirrors noteUserSent).
func cancelSleepyGoodnight(for characterID: UUID) {
    center.removePendingNotificationRequests(withIdentifiers: [
        Self.sleepyQuestionID(for: characterID), Self.sleepyGoodbyeID(for: characterID)
    ])
}
```

(`scheduleOneShot` is a small new private helper factoring the common
`UNMutableNotificationContent` + `UNTimeIntervalNotificationTrigger` + `center.add` boilerplate
already duplicated across the existing scheduling functions — used by both new stages here.)

Two new `NotificationKind` cases: `.sleepyQuestion`, `.sleepyGoodbye`.

Content (new static file `Services/Notifications/SleepyContent.swift`, single line per
stage, no per-role/vibe variation — matches the exact literal phrasing requested, kept
simple per YAGNI):
- `.sleepyQuestion`: *"I want to sleep, if that's ok can we sleep?"*
- `.sleepyGoodbye`: *"I am sleeping, goodnight"*

Both wrapped in `String(localized:)` per the `IcebreakerPool`/`LikedYouContent` convention —
full 6-language (`de/es/fr/it/pt/tr`) catalog entries required (`[[feedback_localization]]`).

`NotificationDelegate.handleTap`: add both new kinds.
- `.sleepyQuestion`: inject the line, `store.pendingTab = .chat` (same as Ghosted/Jealousy).
- `.sleepyGoodbye`: inject the line, **clear `wokenUpAt`** via `LocalConversationStore`
  update (character reverts to genuinely asleep), `store.pendingTab = .chat`.

If the user sends any message before `.sleepyGoodbye` fires, `ChatViewModel` calls
`cancelSleepyGoodnight` and the 10-minute clock restarts from that new message — matches
"if no answer within 5 more minutes, goodbye."

## 4. Daily bedtime announcement

New `NotificationKind.bedtime`. New `NotificationScheduler.rescheduleBedtime(characters:)`,
called from `onForeground` alongside the other four reschedule calls:

```swift
func rescheduleBedtime(characters: [Character]) {
    for character in characters {
        let id = Self.bedtimeID(for: character.id)
        guard !BlockedCharactersStore.isBlocked(character.id),
              let stored = LocalConversationStore.shared.load(for: character.id),
              stored.level >= 5,                      // level gate — proactive only, per user
              let schedule = stored.schedule,
              let fireAt = nextSleepBlockStart(schedule: schedule, from: Date())
        else {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            continue
        }
        // schedule .bedtime at fireAt, same one-shot helper as section 3
    }
}
```

`nextSleepBlockStart` is a small new pure helper (lives next to `ScheduleLookup`, same
weekday/weekend-aware `HH:mm` parsing) that finds the next `isSleep` block's start time —
today if it hasn't passed yet, otherwise tomorrow's applicable (weekday/weekend) schedule.

Fires: *"I am sleeping, goodnight"* — same static content/localization as section 3's
`.sleepyGoodbye` (identical text, reused, not duplicated).

`NotificationDelegate.handleTap`: add `.bedtime` — inject the line, `store.pendingTab =
.chat`. Unlike `.sleepyGoodbye`, this does NOT need to clear `wokenUpAt` (bedtime only
fires when there was no wake-override active in the first place — `rescheduleBedtime`
doesn't check `wokenUpAt`, but in practice a woken-up character's idle-timeout pair from
section 3 would already be governing that state; both mechanisms can coexist since they
use different notification IDs).

**Level gate**: only characters at relationship level ≥5 send this proactive daily
announcement. Section 3 (idle-timeout, user-triggered) and section 6 (in-chat agreement,
user-triggered) apply at every level — the gate is specifically for *unprompted* daily
texts, not for direct responses to what the user did.

## 5. Notification gating for the 4 existing triggers

- **Ghosted** (`rescheduleGhosted`): fire time is `lastMessage.createdAt + roleInterval`
  (up to 48h later for `distant`). After computing `fireAt`, check whether that timestamp's
  time-of-day falls inside the character's sleep block (schedule + weekday/weekend of that
  future date). If so, push `fireAt` forward to the block's `end` time on that date (their
  real wake moment) instead of leaving it mid-sleep.
- **Jealousy** (`armJealousyTimer`, 2-10min window) / **LevelUp**
  (`evaluateLevelUpOnBackground`, 60s window): windows too short to bother time-shifting —
  add `!CharacterSleepState.isEffectivelyAsleep(stored:)` to each function's existing
  `eligible` filter.
- **LikedYou** (`rescheduleLikedYou`): per this session's earlier change, already picks a
  random bot once daily — **also randomize the fire hour** (was hardcoded 13:00; pick a
  random hour in a reasonable daytime window, e.g. 9-22) instead of fixed 13:00. Exclude any
  candidate bot whose own schedule has them asleep at that randomly-chosen hour today from
  the `eligible` pool.

## 6. Natural in-chat sleep-agreement

- Client (`ChatViewModel`): computes `nearSleepTime: Bool` — true if `ScheduleLookup`'s
  current-or-upcoming sleep block starts within 1 hour, or the character is already in it.
  Sent to the `chat` function alongside the existing `currentActivity` field.
- Server (`chat/index.ts`): new rule appended to system prompt (English, per
  `[[feedback_grok_prompts_english]]`) — if the user asks the character to go to sleep:
  agree naturally only if `nearSleepTime` is true; otherwise decline **in whatever way
  actually fits that character's `personality_role`, `vibe`, and current relationship
  level** (a shy/low-level character declines differently than a crazy/high-level one) —
  no fixed tone baked into the instruction, reasoned per-character same as every other rule
  in this system prompt (matches the `VARIATION_RULE`/`MEDIA_REQUEST_RULE` philosophy
  already established: instruct intent, never hardcode phrasing).
- After the normal reply, if `nearSleepTime` was true, one small classifier call (same
  pattern as `classifyPrivacy` for NSFW photos) checks: did the reply actually agree to go
  to sleep (not just discuss the topic)? Returns a new `wentToSleep: boolean` field on the
  response.
- Client: `wentToSleep == true` → `manualSleepAt = Date()`, clear `wokenUpAt` if set.

## Out of scope

- No Notification Service Extension / live network calls at notification-fire-time (not
  feasible without Xcode + a new app-extension target in this environment) — all sleep-
  related notification content is static, matching the existing 4 types' pattern.
- No per-role/vibe variation for the idle-timeout or bedtime lines — single string each,
  matching the literal phrasing requested.
- Multiple `isSleep` blocks per day (schedules could theoretically have more than one) are
  handled by `nextSleepBlockStart` finding whichever comes first chronologically — no
  special-casing beyond that.
