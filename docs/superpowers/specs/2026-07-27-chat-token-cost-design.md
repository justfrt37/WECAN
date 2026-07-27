# Chat Edge Function — Token/API Cost Reduction

Scope: `supabase/functions/chat/index.ts` only. First of four planned optimization
passes (LLM token/API cost → backend perf → client RAM/perf → UI/UX), chosen
first because it's the most direct $ lever.

## Problem

`chat/index.ts` calls Grok on every message with (a) a full static system
prompt of ~15 concatenated rule blocks, (b) up to `KEEP_RECENT` (20) raw
history messages resent every turn, (c) a 600-token reply budget, and (d) a
per-message DB round trip to fetch the relationship-level directive. Static
system-prompt content is already ordered to preserve xAI prompt-cache prefix
matching (`x-grok-conv-id` header for cache locality — see existing comments
in the file), but the recent-history window is NOT cache-friendly (it slides
every turn), making it the largest recurring uncached input-token cost.

## Changes

### 1. Shrink `KEEP_RECENT`: 20 → 12

Cuts per-turn resent-history tokens by ~40%. Since summarization triggers on
`agedOut = total - KEEP_RECENT > summarizedCount`, a smaller window means
messages age into summary sooner — summarization (and its own Grok call,
500 max_tokens) fires more often. Accepted tradeoff: summarization is a
single bounded call per ~N messages vs. resending history on *every*
message, so net token cost still favors the smaller window.

### 2. Lower reply `max_tokens`: 600 → 350

The persona is instructed to write short, casual texting-style replies
(`TEXTING_STYLE_RULE`) capped at 3 `[PAUSE:n]` segments
(`DRAMATIC_PACING_RULE`, enforced server-side in `parseReplySegments`). 600
tokens is more headroom than that output shape needs; 350 still leaves
margin. Applies to the main reply call only — `classifySleepAgreement` (5
tokens) and summarization (500/1500 tokens) are unaffected.

### 3. In-memory directive cache, 5 min TTL

`fetchDirective(characterId, role, level)` currently does 1-2 DB round trips
(`character_level_overrides` then `role_level_scripts` fallback) on every
single message, but the result only changes when the user levels up or a
developer hand-edits a directive in the DB (active during current tuning
work — hence the TTL rather than caching forever per warm instance).

Add a module-level `Map<string, { directive: string; expiresAt: number }>`
keyed by `override:${characterId}:${level}` or `script:${role}:${level}`.
On call: check cache, return if fresh; otherwise hit DB as today and store
with `expiresAt = now + 5 * 60_000`. No invalidation beyond TTL expiry —
acceptable staleness window given directives aren't safety-critical.

### 4. Conservative trim of overlapping static rule blocks

`TEXTING_STYLE_RULE` and `VARIATION_RULE` each end with their own
"never sound formal/robotic/translated" closing line (mechanics-focused in
one, content-variety-focused in the other). Collapse into a single shared
closing sentence appended once, after both blocks, rather than duplicated
in each. Every other rule block (language detection, `IMAGE_CAPTION_RULE`,
`sleepRule`, `DRAMATIC_PACING_RULE`, etc.) is left untouched — those carry
comments citing specific live-test verification (e.g. "8/8 live test",
"verified 2026-07-05 against all 7 test phrases") and rewriting them risks
silently regressing tuned behavior without re-running those tests.

## Explicitly out of scope for this pass

- Model choice (`grok-4-1-fast-non-reasoning`) — already the fast/cheap tier.
- Summarization and `classifySleepAgreement` call logic — already
  conditional/minimal.
- Flat 1-token-per-message charge — a monetization decision, not a cost
  lever.
- `photoDownloadReaction` branch duplicating the memories/behaviors fetch
  and system-prompt assembly logic from the main path — real cleanup item,
  but it's a code-duplication/maintainability issue, not a token-cost one.
  Candidate for the backend-perf pass.
- Batching the sequential DB awaits (character fetch, directive fetch,
  memories, behaviors, message count) with `Promise.all` — latency win, not
  a token-cost win. Candidate for the backend-perf pass.

## Testing

No automated test suite for this edge function currently. Verify manually
post-deploy: send a message, confirm reply still short/in-character with
`[PAUSE:n]` splitting still working; send 12+ messages to confirm
summarization still fires and old context still surfaces via
`[MEMORIES]`/summary; edit a directive row in DB and confirm it takes effect
within 5 minutes without a redeploy.
