# LocalConversationStore — In-Place Updates Instead of Full Rebuild

Scope: `aiGirlfriend/Services/LocalConversationStore.swift` and
`aiGirlfriend/ViewModels/ChatViewModel.swift` (`updateCache`). Part of the
client RAM/perf optimization pass.

## Problem

`ChatViewModel.updateCache()` runs on every message-producing event (`send`,
`sendUserVoice`, `sendUserPhoto`, `sendImageRequest`,
`applyPostReplyEffects`, `reactToPrivateDownload` — at least 7 call sites).
Each call:

1. Computes `realMessages()` — `Array(messages.dropFirst())`, which is an
   O(n) element copy (converting an `ArraySlice` to `Array` copies out),
   not just a COW reference bump.
2. Reads the existing `Stored` from the in-memory dict.
3. Constructs a **brand new `Stored` struct** with that freshly-copied full
   message array plus the other fields.
4. Writes the whole new `Stored` back into `mem[userKey()][id]`.

For a long-running relationship (months of chatting, hundreds/thousands of
messages), every single new message triggers a full copy of the entire
prior history, every time. `LocalConversationStore.mem` itself is also
unbounded — it holds full `Stored` (all messages) for every character
touched in the session, for the life of the process.

## Change

Give `LocalConversationStore` in-place mutation entry points instead of
requiring callers to reconstruct the whole `Stored` value:

- `appendMessage(_ message: Message, for id: UUID)` — appends directly to
  the existing stored array via `mem[userKey()]?[id]?.messages.append(...)`
  (in-place dictionary-value mutation, no full-array copy, no full `Stored`
  reconstruction).
- `updateFields(for id: UUID, level: Int?, levelProgress: Double?, msgCounter: Int?, ...)`
  — mutates only the changed scalar fields on the existing stored value in
  place, leaving `messages` untouched.

`ChatViewModel.updateCache()` is replaced at each call site by the specific
mutation that call site actually needs (usually "append the message I just
added to `messages`" + "update level/counter fields"), rather than one
catch-all that always rebuilds everything.

`realMessages()` usage is reduced to only where a full-array snapshot is
actually needed (e.g. building the request payload to send to the server) —
not on every cache-update call.

## Explicitly out of scope

- Capping in-memory history length / evicting old messages from the live
  session (`mem` growing across characters visited in one session) — a
  bigger, riskier change (affects what context is available for
  summarization, `realAssistantCount`, etc.). Noted as a candidate for a
  future pass, not bundled into this one.
- Changing `Stored` from struct to class — sticking with in-place dictionary
  mutation (Swift dictionaries support in-place value mutation via
  subscript without full reassignment) rather than a reference-type
  rewrite, to keep the change minimal and behavior-preserving.

## Testing

No automated tests for this file currently. Verify manually: send several
messages in a row, confirm history/level/summary state is identical to
current behavior (nothing regresses — level-up events, summarization
triggering at the right message count, chat cache surviving app
backgrounding). Sanity-check with Instruments (Allocations) that a long
chat session no longer shows repeated full-array allocations on each send.
