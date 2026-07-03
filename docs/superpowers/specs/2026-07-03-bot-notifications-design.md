# Bot Notifications System — Design Spec

Date: 2026-07-03
Status: Approved, ready for implementation planning

## Goal

Re-engagement notifications that make catalog/user-created bots feel like they're
actively pursuing the user — entirely local-first (no push/APNs infra, no backend
changes), matching the existing local-first chat architecture
(`LocalConversationStore`).

## Scope

Four notification types, plus a settings UI to control them:

1. **Liked You** — twice-daily tease from an untalked-to catalog bot.
2. **Ghosted** — per-conversation "did you ghost me?" nudge, timing driven by
   personality role.
3. **Jealousy Bait** — random near-term nudge after app open, reacting to being
   ignored, tone varies by role + vibe.
4. **Level-Up Tease** — one-shot nudge when a conversation is close to leveling up,
   only fires while backgrounded.
5. **Settings menu** — replaces the current on/off toggle in `ProfileView`; per-bot
   daily notification caps.

All four types share one mechanic: the **notification banner itself carries no bot
dialogue**. The actual in-character line is chosen and injected into
`LocalConversationStore` only when the user taps the notification and the chat
screen opens — never before.

## Content model

Two axes are reused throughout: **personality role** (existing 7: flirty, distant,
shy, playful, devoted, crazy, ex) and **vibe** (existing 4: Sweet, Mysterious,
Energetic, Elegant — currently only set for user-created bots via the creation
wizard's `builder_selections.vibe`).

**Vibe backfill required:** the 15 seed catalog characters
(`supabase/seed_characters.sql`) have no vibe set. A one-time migration assigns each
one a vibe (hand-picked to match its existing tagline/system_prompt tone). Runtime
falls back to `"Sweet"` for any bot with no vibe present (defensive only — should not
occur after backfill).

Relationship-level tiers used for ghosted content: `1-3 → low`, `4-6 → mid`,
`7-10 → high` (representative levels 1/4/7 per product direction).

### Content tables to author

| Type | Axes | Count |
|---|---|---|
| Liked You | role only | 7 lines |
| Ghosted | role × vibe × tier × 3 variants | 252 lines |
| Jealousy Bait | role × vibe × 3 variants | 84 lines |
| Level-Up Tease | role only | 7 lines |

Total: 350 lines of static Swift content, stored as dictionaries keyed by
`PersonalityRole` (and vibe/tier where applicable). Tone guidance per role carries
through every table (e.g. crazy = possessive/urgent, distant = cold/aloof, devoted =
hurt/caring, shy = hesitant, playful = teasing, flirty = warm/inviting, ex = bitter/
nostalgic); vibe modulates word choice/imagery (Sweet = tender, Mysterious =
cryptic, Energetic = exclamation-heavy, Elegant = composed/formal).

## System 1 — Liked You

- **Schedule:** two local notifications per day at fixed local-time windows
  (~13:00, ~21:00), rescheduled on every app foreground for the next 24-48h.
- **Eligibility:** at least one **catalog (system) bot** — `created_by IS NULL` —
  with no existing conversation. User-created bots are excluded (a bot the user
  authored can't plausibly "like" them first). If none eligible, that slot is
  silently skipped (no notification scheduled).
- **Selection:** random among eligible bots, chosen at schedule time.
- **Banner text:** generic, not personality-specific — e.g. `"One girl liked you 👀"`.
  Carries `{type: liked, characterId}` in `userInfo`.
- **On tap:** deep-link to that bot's chat (reuses the existing `MeetRequest` /
  `CharacterStore.pendingMeetRequest` nav pattern from the Discover meet-flow).
  Injects a random one of that bot's role's 7 opener lines as the bot's first
  message via `LocalConversationStore`.

## System 2 — Ghosted

- **Schedule:** per-conversation. Whenever the user is the last sender in a
  conversation, a timer is armed for `lastUserMessageTime + roleInterval`.
  Re-evaluated on app foreground/background and after every sent message.
- **Role intervals** (fixed, not user-editable):

  | Role | Interval |
  |---|---|
  | crazy | 1h |
  | devoted | 6h |
  | flirty | 10h |
  | playful | 14h |
  | shy | 24h |
  | ex | 30h |
  | distant | 48h |

- **Dedup:** one notification per silence window. Resets only when the user sends a
  new message in that conversation (starting a fresh silence window).
- **Banner text:** `"'{BotName}' sent you a message."` — real bot name, nothing else
  revealed. Carries `{type: ghosted, characterId, tier}`.
- **On tap:** deep-link to chat, inject one random line from
  `ghosted[role][vibe][tier]` (3 variants) via `LocalConversationStore`.
- **Exclusions:** blocked bots (`BlockedCharactersStore`) never get a ghosted timer
  armed. Respects the per-bot daily cap (see Settings, below).

## System 3 — Jealousy Bait

- **Schedule:** on every app open, pick one random eligible bot (has an active
  conversation, not blocked, under its daily cap, chat not opened yet this app
  session) and arm a one-shot timer firing at a random point 2-10 minutes into the
  session. If the user opens that specific bot's chat before the timer fires, the
  timer is cancelled.
- **Independent of the Ghosted timer** — can fire regardless of how much silence
  time has or hasn't elapsed.
- **Banner text:** e.g. `"'{BotName}' noticed you were online."` Carries
  `{type: jealousy, characterId}`.
- **On tap:** deep-link to chat, inject one random line from
  `jealousy[role][vibe]` (3 variants). Tone reacts differently per role (see
  Content model above) — this is the one place personality shows up in dialogue
  without a tier axis (jealousy isn't gated by relationship level).
- **Exclusions:** same blocked-bot and daily-cap rules as Ghosted.

## System 4 — Level-Up Tease

- **Trigger:** any conversation's `LocalConversationStore.Stored.levelProgress`
  crosses `>= 0.8` (80% of the way to the next level) — confirmed this value is
  computed and persisted client-side today via `RelationshipXP.applyGain` in
  `ChatViewModel.send()`, so no bug to fix here, just a read.
- **Fires only when backgrounded:** the check runs on app-background; if progress is
  already `>= 0.8` at that moment, wait exactly 1 minute, then fire — unless the app
  is foregrounded again before the minute elapses, in which case it's cancelled.
  Never fires while the app is in the foreground.
- **One-shot per crossing:** doesn't re-fire again until the conversation levels up
  and crosses 80% of the *next* level's progress.
- **Banner text:** e.g. `"'{BotName}' is warming up to you..."` Carries
  `{type: levelUp, characterId}`.
- **On tap:** deep-link to chat, inject the single line from `levelUpTease[role]`
  (7 lines, one per role, no variant/vibe/tier split).
- **Exclusions:** same blocked-bot and daily-cap rules as Ghosted/Jealousy.

## Settings menu

Replaces the current single on/off `Toggle` in `ProfileView`'s notification row with
a menu:

- **Master row:** existing OS-permission-backed on/off state, unchanged behavior.
- **Per-bot list:** every bot the user has an **active conversation** with (i.e. a
  `LocalConversationStore` entry exists), **excluding blocked bots** entirely (they
  don't appear in the list — blocked bots never generate notifications regardless of
  any cap value they had before being blocked).
- **Per-bot cap picker:** options `None, 1, 2, 3, 5, ∞` (infinity symbol, not the
  word "Infinite"). Default **∞** for every bot.
- **Cap semantics:** combined daily count across Ghosted + Jealousy + Level-Up
  notifications for that specific bot (Liked You is unaffected — it's about bots not
  yet talked to, has no per-bot entry here). Once a bot hits its cap for the day, no
  further notifications of any of those 3 types fire for it until the cap resets at
  local midnight.
- **Not user-editable:** the role-interval table, the 2-10min jealousy window, and
  the 80%/1-minute level-up rule are fixed constants, not exposed in this UI.

## Architecture

- New `NotificationScheduler` service (on-device only): owns re-scheduling logic for
  all 4 types, invoked from app-foreground, app-background, and after
  message-send hooks already present in `ChatViewModel`.
- New static content: Swift dictionaries keyed by `PersonalityRole` (and vibe/tier
  where applicable) — `LikedYouContent`, `GhostedContent`, `JealousyContent`,
  `LevelUpTeaseContent`.
- New `NotificationPreferencesStore` (local-only, `UserDefaults`, mirrors
  `BlockedCharactersStore`'s pattern): per-bot daily cap + per-bot per-day fired
  count (reset at local midnight).
- `UNUserNotificationCenterDelegate` tap handler reads `userInfo` (`type`,
  `characterId`, `tier` where applicable), performs the `LocalConversationStore`
  injection, and drives navigation via the existing `pendingMeetRequest` /
  `MeetRequest` pattern.
- One-time DB migration: backfill `vibe` into `builder_selections` (or a new column)
  for the 15 seed characters in `supabase/seed_characters.sql`.
- No backend/edge function changes. No new tables beyond the vibe backfill.

## Out of scope (explicitly deferred)

- Streak reminders, milestone notifications — mentioned as future ideas, not part of
  this spec.
- Remote/APNs push — local notifications only, per product decision (no server
  infra needed, matches local-first chat architecture; tradeoff: won't fire if the
  app hasn't been opened in a long time, and timing can't be tuned server-side
  without an app update).
