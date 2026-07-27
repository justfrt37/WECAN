# Engagement, Dramatic Pacing & Auto-Memory Design

Status: approved for planning
Date: 2026-07-27

## Problem

Bots feel passive and flat: replies are single-line, reactive-only, don't
probe the user or reference shared history proactively, and sexual/romantic
interest ramps in too slowly (effectively starting around level 3 for most
characters instead of being present, if muted, from level 1). There's no
sense of dramatic timing — every reply lands as one instant block of text —
and persistent facts about the user/relationship only get captured when the
user manually taps "Anı Ekle"; everything else lives only in the compressible
running summary and can get lost.

## Goals

1. Bots ask questions, reference memories/past conversations, and
   occasionally switch topic on their own initiative — not purely reactive.
2. Sexual/romantic interest present from relationship level 1, scaling with
   level; reserved/shy character archetypes express it indirectly (puns,
   teasing) rather than being silenced until later levels — driven by the
   model reasoning from its own persona description, not a hardcoded role
   branch.
3. Bots proactively reference recent-gap timing ("how was your day") as a
   conversation opener, and can improvise a short, schedule-consistent
   account of their own day when asked (or after asking the user about
   theirs).
4. Replies can occasionally land as up to 3 paced bubbles with real delay
   between them (dramatic hesitation, or just natural multi-text rhythm) —
   model-driven, not scripted.
5. Durable facts get captured automatically into the `memories` table (not
   only via manual add), deduplicated against what's already stored.
6. None of the above should meaningfully increase API spend — new prompt
   content is static (cache-friendly), and a pre-existing system-prompt
   ordering issue that already hurts cache-hit rate gets fixed as part of
   this work.

## Non-goals

- No DB schema migrations (memories/messages tables unchanged).
- No new Grok API calls — auto-memory extraction piggybacks the existing
  `summarizeMessages` call (already fired every 20 messages by the client).
- No change to voice-chat (`voiceChat: true`) or image-reaction-chat pacing
  — multi-bubble/pause behavior is plain-text-turn only.
- No per-role hardcoded branching for the shy/reserved archetype — the model
  infers tone from its own character description, same convention already
  used by `sleepRule`/`wrapDirective`.

## Design

### 1. New static prompt directives (`supabase/functions/chat/index.ts`)

All added as `const` strings / small functions, same pattern as the existing
`TEXTING_STYLE_RULE`, `VARIATION_RULE`, `humorDirective`, etc. — no DB
migration, no new API calls.

**`engagementDirective(level)`** (replaces nothing, net-new, applied every
plain-text turn):
- Ask follow-up questions; don't just answer and stop.
- Actively use the `[MEMORIES]` / `[SHARED HISTORY]` / summary blocks already
  injected elsewhere in the system prompt — reference past conversations,
  make callbacks ("how did X go"), not just recall passively when asked.
- Occasionally (not every turn) pivot to a new topic — a question, an
  observation, a hypothetical — drawing on `interests` (already injected) or
  general curiosity. Most turns should NOT do this; it's a texture, not a
  tic.
- Sexual/romantic interest is present from level 1, scaling in intensity with
  level via a level-driven formula (independent of the DB-stored
  `fetchDirective` stage script, which continues to gate deeper
  boundaries/pacing — this is a baseline-interest layer, not a replacement).
  Model filters the intensity/expression through its OWN character voice:
  reserved/shy personas show interest indirectly (teasing, puns, indirect
  signals); confident personas show it directly. No hardcoded role-name
  branch in code — the instruction is generic, the model reasons from its
  own persona description already present in `systemPrompt`.

**`DRAMATIC_PACING_RULE`** (plain-text turns only, i.e.
`!voiceChat && !imageReactionChat`):
- Model MAY split a reply into up to 3 short beats using an inline tag
  `[PAUSE:n]` (n = 1–5 seconds) between beats.
- Only when a genuine moment calls for it (hesitation, processing something
  the user said, building tension, or just natural back-to-back texting
  rhythm) — never as a default habit on every message.
- Explicitly told this is improvisation, not a fixed script — no canned
  example patterns baked into the rule text itself.

**`dayAwarenessDirective`** (folds into `turnContext`, next to the existing
`timeContext` call):
- `timeContext` already computes gap-since-last-message + time-of-day; it
  currently only shades tone. Extend its guidance so the model can actively
  use it as an opener (ask about the user's day/recent events), not just a
  mood hint.
- When the user asks about the bot's day, or after the bot itself asks the
  user about theirs, the bot may improvise a short, natural anecdote
  consistent with its own schedule (`currentActivity` + the character's
  weekday/weekend schedule blocks, already available server-side). Loosens
  the current hard "never mention activity unless asked" rule specifically
  for this day-talk case; the blanket anti-repetition rule stays for
  `currentActivity` otherwise. Anecdote must vary each time — never a fixed
  script.

### 2. Multi-bubble reply parsing (server)

New helper in `chat/index.ts`:

```ts
function parseReplySegments(raw: string): {
  plainText: string;
  segments: { text: string; delaySeconds: number }[];
}
```

- Splits `raw` on `/\[PAUSE:(\d)\]/`, capturing the delay before each
  following segment.
- Clamps every captured `n` to the 1–5 range server-side regardless of what
  the model outputs (defense-in-depth, same posture as other clamps in this
  file).
- Caps total segments at 3 — anything beyond that gets merged into the 3rd
  segment (backstop; the rule already tells the model to cap at 3).
- `plainText` = all segment text joined with spaces, tags stripped — this is
  what gets stored in the `messages` table (no schema change) and what feeds
  `classifySleepAgreement` and the summarization prompt, both unchanged.
- `segments` is returned to the client for THIS turn only, never persisted
  structurally — reopening a conversation later replays `plainText` as a
  single bubble, which is an acceptable degradation (only live delivery gets
  the paced animation).
- Applied only when `!voiceChat && !imageReactionChat`.

### 3. System-prompt ordering fix (cache-hit rate)

Pre-existing issue, not caused by this work but made worse by it (memories
now grow more often via auto-extraction — see §5): `memories`/`behaviors`
blocks currently sit early in the `system` string
(`chat/index.ts:851-858`), ahead of most static rule blocks. Per xAI's
prompt-caching docs, any change earlier in the prefix invalidates the cached
prefix for everything after it — so every time memories/behaviors change,
all the static rule text that follows them in the string stops being cache
hits until the next identical-prefix call.

Fix: reorder system-prompt assembly so the sequence is:

1. Baked `systemPrompt` (character definition, static)
2. All static RULE constants (`TEXTING_STYLE_RULE`, `VARIATION_RULE`,
   `CONTINUITY_RULE`, `engagementDirective`, `DRAMATIC_PACING_RULE`, mode
   rules, etc.)
3. Level-based directives (`fetchDirective` result, `humorDirective`) —
   change only on level-up, relatively rare
4. Variable-per-conversation blocks LAST: `exHistory`, `memories`,
   `behaviors`, `convo.summary`
5. (unchanged) turn-specific content stays out of `system` entirely, in the
   final user message, as it already is (`turnContext`)

This maximizes the stable prefix length so cache invalidation from
memory/summary growth only drops the tail of the prompt, not the whole
thing.

### 4. API response schema

`reply` (string) unchanged — always the full `plainText`, backward
compatible with any other consumer.

New optional field on the response: `replySegments: { text: string;
delaySeconds: number }[]`, populated only for plain-text turns. Absent for
voice/image-reaction turns.

### 5. Auto-memory extraction

The `summarizeMessages` branch (client-triggered every 20 messages) is
currently stateless w.r.t. `memories` — it only sees `existingSummary` and
`previousSchedule`. Extending it:

- Client adds `conversationId` to the `summarizeMessages` request body
  (new field on an existing call, not a new call).
- Server fetches existing `memories` rows for that conversation before
  building the extraction prompt (server-authoritative, matches this file's
  established "zero local" philosophy).
- The existing summarization prompt gains a second instruction: extract
  durable atomic facts (name, preferences, promises, key relationship
  moments) not already present in the existing memories list, output them
  as a JSON array alongside the existing `summary`/`schedule` fields.
- Server inserts each new fact as a row into `memories` — same schema/table
  already used by manual "Anı Ekle", no migration. Dedup is prompt-driven
  (existing memories shown to the model with an explicit "don't repeat
  these" instruction), not a code-level dedup pass.

### 6. Client changes (iOS)

`ChatService.swift`:
- `ChatResponse` / `ChatReply` gain optional `replySegments: [ReplySegment]`
  (`ReplySegment { text: String; delaySeconds: Double }`).

`ChatViewModel.swift`, `send()` (currently ~line 285-304, single typing-then-
append):
- If `replySegments` is present and non-empty: loop over segments — show
  typing indicator (existing `TypingTiming.duration`, upper-bounded by the
  segment's own `delaySeconds` for the 2nd/3rd bubble), append one `Message`
  per segment, wait `delaySeconds` before the next.
- If absent (voice/image-reaction turns, or any older response shape):
  fall back to the existing single-bubble path unchanged — zero-risk
  rollout, no behavior change for those turns.

## Testing plan

Live multi-turn manual testing (no automated test suite exists for this
function currently):

1. Sexual/curious tone present at level 1 for both a confident-role and a
   reserved/shy-role character — confirm the reserved one expresses interest
   indirectly, not silently.
2. Topic-switch fires occasionally across a long conversation, not every
   turn.
3. Day-narrative: ask the bot about its day twice in different sessions,
   confirm it stays broadly consistent with its own schedule blocks and
   doesn't contradict itself, while wording varies.
4. `[PAUSE:n]` segments render as separate bubbles client-side with visible
   typing gaps; confirm cap at 3 segments holds even if the model tries to
   emit more.
5. Auto-memory extraction: run 40+ messages (2 summarization cycles),
   confirm no duplicate facts get inserted across cycles.
6. Spot-check `x-grok-conv-id` cache behavior isn't regressed by the
   reordering (no functional test available for this — visual confirmation
   that turnContext/memories/summary still only appear in the last
   positions of `system` and in the final user message, not scattered).
