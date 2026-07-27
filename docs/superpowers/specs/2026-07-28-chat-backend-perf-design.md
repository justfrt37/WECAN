# Chat Edge Function — Backend Perf & Cleanup

Scope: `supabase/functions/chat/index.ts`, plus a documentation-only note on
unused deployed functions. Third of four planned optimization passes
(token/API cost → **backend perf** → client RAM/perf → UI/UX). Client RAM/
perf and part of UI/UX were done out of order per conversation; this pass
picks up the remaining backend-perf items flagged during that work.

## 1. Parallelize independent DB round trips

`chat/index.ts`'s reply path currently awaits several independent Supabase
queries sequentially. None of these depend on each other's *results*, only
on inputs already available before they run:

- **Group A** (need only `characterId`/`uid`, run right after parsing the
  request body): `character` fetch (`personality_role, ex_history,
  interests`) and `convoRows` fetch (existing conversation lookup). Currently
  two sequential awaits — batch with `Promise.all`.
- **Group B** (need `characterId`/`personalityRole`/`currentLevel` from
  Group A, plus `conversationId` once `convo` is resolved/created):
  `fetchDirective()`, the `memoryRows` fetch, the `behaviorRows` fetch, and
  the `recent` messages fetch. Currently four sequential awaits — none
  depend on each other, batch with `Promise.all`.

Each round trip is roughly 20-50ms; batching these two groups should cut
~100-150ms off every chat reply's latency with no behavior change (pure
reordering, same queries, same results).

Not touched: the message-count fetch and summarization logic near the end
of the handler stay sequential — the count genuinely depends on the
just-inserted messages, so it can't move earlier.

## 2. Share the memories/behaviors/system-prompt-assembly logic

The `photoDownloadReaction` branch (`body.photoDownloadReaction === true`)
re-implements, nearly verbatim, logic that the main reply path already has:
fetching `memories`/`conversation_behaviors` for the conversation, building
the directive via `fetchDirective` + `wrapDirective`, appending `exHistory`,
appending the `[MEMORIES]`/`[BEHAVIOR PREFERENCES]` blocks, and appending
`languageDirective`. Today these are two separate copy-pasted blocks of
~20 lines each.

Extract a shared helper, e.g.
`buildSystemPromptBase(characterId, personalityRole, conversationId, currentLevel, currentProgress, exHistory, detectedLanguage): Promise<string>`,
that does: fetch directive, fetch memories, fetch behaviors (batched per
item 1's Group-B pattern), and return the assembled string through the
`[BEHAVIOR PREFERENCES]` block (i.e. everything both call sites need,
before their respective branch-specific rule blocks are appended). Both the
main reply path and `photoDownloadReaction` call this helper instead of
duplicating the fetch+assembly logic.

This is a pure refactor — no behavior change, no new queries, just shared
code. It also means the parallelization from item 1's Group B only needs
to be implemented once.

## 3. Unused deployed functions — documented, not deleted

The following edge functions are deployed to the prod Supabase project but
appear to be one-off test/experiment artifacts, not part of any live client
flow: `chat-image-civitai-test`, `civitai-whatif-test`,
`xai-bootstrap-test`. The `dev-*` family (`dev-token-tools`,
`dev-create-character`, `dev-update-character`, `dev-upload-image`,
`dev-list-voices`) may still be active dev tooling — not clear from code
alone.

**Decision: document only, no deletion in this pass.** Listed here as
cleanup candidates for a future, explicitly-scoped pass (worth confirming
with `supabase functions list` invocation counts/last-invoked timestamps
before deleting anything, since unused-looking code can still be someone's
manual test harness).

## Explicitly out of scope

- Any change to what the summarization/message-count logic does — only
  the earlier fetches are reordered.
- Deleting any deployed function (see item 3).
- The `dev-*` function family's actual usage — not investigated, flagged
  only.

## Testing

No automated test suite for this edge function. Verify manually post-deploy:
send a normal message (confirm reply/history/memories still correct —
parallelizing shouldn't change any returned data, only timing). Trigger
`photoDownloadReaction` (download a private photo) and confirm the reaction
still references memories/behaviors/shared-history correctly through the
new shared helper. Time a few requests before/after to sanity-check the
expected latency improvement.
