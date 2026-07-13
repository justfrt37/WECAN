# Missed You (late-night) + Good Morning notifications — design

## Context

The app has 4 existing proactive bot-notification systems (Liked You, Ghosted,
Jealousy Bait, Level-Up Tease, plus Bedtime Announcement and the Sleepy
Goodnight pair) — see `docs/superpowers/specs/2026-07-03-bot-notifications-design.md`
and `NotificationScheduler.swift`. This adds two more:

1. **Missed You** — between 10pm and midnight, one random actively-talked-to
   (not ghosted) bot texts the user saying she can't sleep / is thinking about
   them, weighted so higher-level bots are more likely to be the one who does.
2. **Good Morning** — between 7am and noon, each bot that's crossed its own
   personality-specific intimacy threshold sends its own good-morning text,
   timed relative to her real schedule wake-up time. The higher the level, the
   closer to her actual wake time it fires; different personalities start at
   different levels and close the gap at different rates.

Both are pure local notifications — no network calls, no server involvement,
same as every existing notification type in this app. All text comes from
curated line pools (English + Turkish), not live AI generation, to match the
existing Ghosted/Jealousy/Bedtime pattern (`GhostedContent.swift` etc.) and
keep this free/instant/offline-safe.

## Missed You

**Eligibility** (evaluated in `NotificationScheduler.onForeground`, mirrors
Jealousy Bait's eligibility exactly):
- Not blocked (`BlockedCharactersStore.isBlocked`)
- Has an active `LocalConversationStore` entry
- `stored.ghostedAt == nil` (post-ghosted freeze applies here too)
- Under its daily cap (`NotificationPreferencesStore.canSendMore`)
- **No sleep-schedule check** — the fiction is that she's texting *despite*
  being asleep/tired, so her own schedule is irrelevant here.

**Selection**: weighted random over the eligible set, weight = `max(1, level)`
(linear — a level-8 bot is ~8x as likely as a level-1 bot). Exactly one bot is
picked per calendar day.

**Timing**: a random point between 22:00 and 23:59, chosen once per day and
persisted (mirrors `LikedByStore.hasPickedToday()`) so re-foregrounding during
the evening doesn't reroll the bot or the time.

**Content**: new `MissedYouContent.swift`, same shape as `GhostedContent.swift`
(`[language: [role: [vibe: [tier: [lines]]]]]`, tiers low/mid/high by level,
English + Turkish only). Lines read as "can't sleep, thinking about you /
missed you today" in each role's voice — NOT "why did you go quiet" (that's
Ghosted's territory; Missed You is unprompted and affectionate/needy, not
accusatory).

**Notification kind**: `NotificationKind.missedYou`. Title matches the
existing pattern: `"\(character.name) sent you a message."`. Tapping/delivery
injects the line via `NotificationDelegate` and routes `pendingTab = .chat`,
identical to Ghosted/Jealousy/Bedtime.

## Good Morning

**Per-character, independent** (like Bedtime — every eligible bot can fire
its own; no single company-wide pick).

**Eligibility + timing curve** — per `personality_role`:

| role | min level | offset @ min level | offset @ level 10 |
|---|---|---|---|
| crazy | 1 | 90 min | 1 min |
| devoted | 1 | 120 min | 1 min |
| flirty | 1 | 180 min | 1 min |
| playful | 1 | 210 min | 5 min |
| shy | 3 | 150 min | 15 min |
| distant | 6 | 180 min | 30 min |
| ex | 7 | 150 min | 45 min |

- Below `min level`, the bot never sends a good-morning text at all.
- At/above `min level`, the offset (minutes after her real wake time) linearly
  interpolates between `offset @ min level` (at that role's min level) and
  `offset @ level 10` (at level 10+, floor).
- Final fire time = `wakeTime + offset`, clamped to **[7:00, 12:00]** (updated
  from the original 8:00–11:30 per user request — gives more headroom at both
  ends while keeping the "morning" framing).
- Wake time comes from a new `ScheduleLookup.nextWakeTime(schedule:from:)`,
  mirroring the existing `nextSleepBlockStart` (same day-scanning approach,
  looks at the block right after the current/next sleep block ends).

**Suppression**: if the user has already sent that bot a message since her
wake time today, no good-morning notification fires for her today. Checked:
- At reschedule time (`onForeground`) — skip scheduling if a qualifying
  user message already exists.
- Reactively — extend `noteUserSent` (already called on every user message,
  already cancels pending Ghosted) to also cancel that bot's pending
  Good Morning notification, so a message sent *after* scheduling but *before*
  the notification fires still suppresses it.

**Content**: new `GoodMorningContent.swift`, same pool shape as
`MissedYouContent.swift`/`GhostedContent.swift`.

**Notification kind**: `NotificationKind.goodMorning`. Same title pattern,
same injection/routing behavior as the other proactive kinds.

## Wiring summary

- `NotificationKind` gains `.missedYou` and `.goodMorning`.
- `NotificationScheduler` gains `rescheduleMissedYou(characters:)` and
  `rescheduleGoodMorning(characters:)`, both called from `onForeground`
  alongside the existing reschedule calls.
- `NotificationScheduler.noteUserSent` additionally cancels that character's
  pending Good Morning notification.
- `NotificationDelegate.handleTap` gets two new cases: inject the picked line,
  route `pendingTab = .chat` — identical shape to Ghosted/Jealousy/Bedtime.
- `ScheduleLookup` gains `nextWakeTime(schedule:from:)`.
- Two new content-pool files under `Services/Notifications/`:
  `MissedYouContent.swift`, `GoodMorningContent.swift`.

## Out of scope

- No live AI/Grok-generated text (explicitly decided against — local
  notifications can't call an API at delivery time, and static pools keep
  this free/instant/consistent with the rest of the system).
- No per-user configuration/toggle for these two systems beyond the existing
  per-bot daily notification cap.
