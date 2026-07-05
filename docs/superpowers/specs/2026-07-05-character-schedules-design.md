# Character daily schedules — design

Date: 2026-07-05

## Problem

Bots have no sense of "what am I doing right now." Every reply is available
instantly regardless of time of day, which breaks immersion — a scientist
character should feel different messaging at 3pm on a Tuesday (at the lab)
vs 11pm on a Saturday (at home, relaxing). The existing `timeContext()` in
`chat/index.ts` only knows the gap since the last message and a rough part
of day (morning/afternoon/evening) — it has no concept of a character's
actual routine.

## Goal

Give each (user, character) conversation a personalized daily schedule
(weekday + weekend variants) derived from the character's personality/
profession, surfaced two ways: (1) silently shapes her reply tone/
availability, (2) a live "At work" / "Commuting home" / "Having dinner"
status line replacing the existing "🟢 Online" text in the chat header. The
schedule evolves over time from facts established in that specific
conversation (piggybacked on the existing summarization cadence).

## 1. Schedule shape

```ts
interface ScheduleBlock {
  start: string;   // "HH:mm", 24h, local device time
  end: string;     // "HH:mm" — may be less than `start` for overnight blocks (e.g. 23:00–07:00)
  label: string;   // short, for UI header — "At work"
  detail: string;  // richer, for prompt injection — "at work in the lab running experiments"
}
interface CharacterSchedule {
  weekday: ScheduleBlock[]; // must cover the full 24 hours, no gaps, including sleep
  weekend: ScheduleBlock[]; // same
}
```

Time is anchored to the **user's device timezone** (the `tzOffsetMinutes`
already sent on every chat request) — no fictional per-character geography
needed, matches how `timeContext()` already behaves today.

## 2. Storage — local, not a new server table

This app is local-first (chat history lives on-device; server only persists
XP/level — see `architecture_swift.md`/`architecture_db.md`). The schedule
follows the same pattern: a new `schedule: CharacterSchedule?` field on
`LocalConversationStore.Stored`, decoded as `nil` for existing stored files
(same "defaults on decode" convention already used for `msgCounter`). No new
DB table — reading "what is she doing right now" is a pure local computation
(current schedule + `Date()` + weekday/weekend), never a network call.

## 3. Generation

**Initial (new edge function `character-schedule`):** On first `ChatView`
load, if `LocalConversationStore` has no cached schedule for this character,
kick off a **fire-and-forget** background call: `{ characterId, systemPrompt
}` → Grok generates a schedule from the character's `system_prompt` alone
(same field already sent on every chat request — already encodes
personality/profession/vibe, no separate DB fetch needed) → `{ schedule }`.
If the user sends a message before this resolves, that turn just omits the
activity context — never blocks sending.

**Refinement (piggybacked on existing summarization):** The
`summarizeMessages` branch of `chat/index.ts` already runs every 20 messages
and returns an updated `summary`. Extend its request to also accept
`previousSchedule: CharacterSchedule | null`, and its response to also
return `schedule` — one Grok call producing both, using the new
conversation snippet + existing summary + character's `systemPrompt` +
previous schedule to decide what changed (e.g. "I quit my job" → the lab
blocks disappear). No new cadence, no added network round-trips beyond what
already runs today.

## 4. Behavioral effect on replies

Client computes the current block locally (see below) and sends its
`detail` string as a new `currentActivity` field on the normal chat
request (same shape/spot as `lastMessageAt` today). `chat/index.ts` appends
a short instruction when present: reflect this naturally in tone/
availability (brief/distracted if at work, relaxed if at home) without
repeating it verbatim every message — same "vary it naturally" principle
already used for `VARIATION_RULE`.

## 5. Client-side "current block" lookup

New pure function (e.g. `ScheduleLookup.currentBlock(schedule:date:)`):
1. `Calendar.current` determines if `date` falls on a weekend
   (`isDateInWeekend`) → picks `weekday` or `weekend` array.
2. Formats `date` as local "HH:mm", finds the block where `start <= now <
   end` — for overnight blocks where `start > end` (e.g. "23:00"–"07:00"),
   matches when `now >= start OR now < end`.
3. Returns `nil` if no block matches (defensive — a malformed generation
   response shouldn't crash anything); callers treat `nil` as "no activity
   context," falling back to the current plain "Online" label with no
   `currentActivity` sent.

`ChatViewModel` exposes `currentActivity: (label: String, detail: String)?`,
recomputed on `loadHistory()` and on a lightweight 60-second repeating
refresh while the view is visible (so a block boundary crossed mid-
conversation, e.g. 17:30 "commuting home", updates without reopening the
chat).

## 6. UI

`ChatView.header`'s existing line (green dot + `Text("Online")`,
`ChatView.swift:148-151`) becomes green dot + `Text(viewModel.currentActivity?.label ?? String(localized: "Online"))`
— reuses the existing space, no layout change.

## Non-goals (explicitly deferred)

- No per-character (shared/catalog-level) schedule — confirmed
  per-conversation/personalized only.
- No explicit "day off" / vacation / sick-day one-off events — schedule is a
  recurring weekday/weekend routine only, refined by real conversation
  facts, not calendar-aware one-time exceptions.
- No timezone other than the user's own device timezone.

## Files touched

- New: `supabase/functions/character-schedule/index.ts`
- Edit: `supabase/functions/chat/index.ts` (`currentActivity` field +
  instruction; `summarizeMessages` branch extended to accept
  `previousSchedule` and return `schedule`)
- Edit: `aiGirlfriend/Services/ChatService.swift` (new
  `generateInitialSchedule`, `generateLocalSummary` gains
  `previousSchedule` param + `schedule` in its return, `sendWithLocalHistory`
  gains `currentActivity` param)
- New: `aiGirlfriend/Models/CharacterSchedule.swift` (`ScheduleBlock`,
  `CharacterSchedule`, both `Codable`)
- New: `aiGirlfriend/Services/ScheduleLookup.swift` (pure `currentBlock`
  function)
- Edit: `aiGirlfriend/Services/LocalConversationStore.swift` (`Stored` gains
  `schedule: CharacterSchedule?`)
- Edit: `aiGirlfriend/ViewModels/ChatViewModel.swift` (`currentActivity`
  property + refresh, initial-generation kickoff, threading
  `currentActivity`/`previousSchedule` through `send()`/`sendVoiceRequest()`/
  `sendImageRequest()`/summarization)
- Edit: `aiGirlfriend/Views/ChatView.swift` (header status line)
