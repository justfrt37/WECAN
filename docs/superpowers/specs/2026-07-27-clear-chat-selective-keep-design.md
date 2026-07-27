# Clear Chat — Selective-Keep Dialog

Scope: `chat/index.ts` clear branch, `ChatService.clearConversation`,
`ChatMaintenance.clearChat`, `ChatViewModel.clearChat`, `ChatView`'s
"Clear Chat" menu item. Part of the UI/UX optimization pass.

## Problem

Today "Clear Chat" is all-or-nothing: `ChatMaintenance.clearChat` wipes the
local cache (`LocalConversationStore.shared.clear`, `store.chatCache`) and
calls `ChatService().clearConversation()`, which sends
`{ clearConversation: true }` to `chat/index.ts`. The server hard-deletes
**all** matching `conversations` rows for that (user, character), which
cascades to `messages` and `memories`. Relationship level, memories, and
behavior preferences are lost every time, even when the user just wants a
fresh message history with the same character they've built a relationship
with.

Two entry points call this today: `ChatView`'s gear-menu "Clear Chat"
button, and `ChatListView`'s long-press "Clear Chat" menu item (list-level,
no open `ChatViewModel`).

## Change

### Client: selective-keep dialog (ChatView entry point only)

`ChatView`'s "Clear Chat" button opens a confirmation dialog with three
independent checkboxes (default: all unchecked, i.e. current full-wipe
behavior is the default path if the user doesn't check anything):

- Keep relationship level/progress
- Keep memories
- Keep behavior preferences

`ChatListView`'s long-press entry point keeps today's behavior (full wipe,
no dialog) — it operates on a list row without a live `ChatViewModel`/level
context, and a full wipe from the list is the expected "start over"
action there.

### Client: wiring

- `ChatMaintenance.clearChat(character:store:keepLevel:keepMemories:keepBehaviors:)`
  — three new parameters, defaulted to `false` so the existing
  `ChatListView` call sites don't need to change.
- `ChatService.clearConversation(character:keepLevel:keepMemories:keepBehaviors:)`
  passes the three flags through to the wire payload (`ChatRequest` gets
  `keepLevel`/`keepMemories`/`keepBehaviors: Bool?` alongside the existing
  `clearConversation: Bool?`).
- Local cache reset (`LocalConversationStore`) mirrors the server: instead
  of `clear(for:)` (full removal), a new `resetKeeping(for:keepLevel:keepMemories:...)`
  clears `messages`, `summary`, `summarizedCount`, `schedule`,
  `wokenUpAt`, `manualSleepAt`, `ghostedAt`, `detectedLanguage`
  unconditionally, and only resets `level`/`levelProgress` to `1`/`0` when
  `keepLevel` is false. (Memories/behaviors aren't stored client-side today
  — server-only tables — so those two flags only affect the server call.)

### Server (`chat/index.ts`, clear branch)

Replace the unconditional
`db.from("conversations").delete().eq(...)` with:

1. Fetch the matching conversation row(s) (same query as today, handles the
   existing dupe-cleanup case).
2. For the most-recent row, run targeted deletes/updates instead of
   dropping the row:
   - Always: delete all `messages` rows for that `conversation_id`.
   - If `!keepMemories`: delete all `memories` rows for that
     `conversation_id`.
   - If `!keepBehaviors`: delete all `conversation_behaviors` rows for that
     `conversation_id`.
   - Always reset: `summary = ''`, `summarized_count = 0`, `schedule = null`,
     `woken_up_at = null`, `manual_sleep_at = null`, `ghosted_at = null`,
     `detected_language = null` (all ephemeral per-conversation state, not
     offered as keep options).
   - If `!keepLevel`: also reset `relationship_level = 1`,
     `level_progress = 0`. If `keepLevel` is true, leave those columns
     untouched.
3. Any OTHER duplicate rows for the same (user, character) (the existing
   dupe-guard case) are still hard-deleted as before — the keep-options
   only apply to the row actually being "cleared", not stray dupes.

This keeps the conversation row alive (so kept level/memories/behaviors
stay attached to it) instead of deleting-and-recreating, which avoids
racing the "don't resurrect a deleted conversation" guard elsewhere in the
file (`convo` creation is deliberately deferred to message-send time, per
existing comments — a kept-row approach sidesteps that entirely since the
row is never actually deleted).

## Explicitly out of scope

- Per-message delete — a separate, smaller feature, not bundled here.
- Keeping `schedule` — not offered as a keep option (always regenerated
  fresh via `character-schedule` on next open, cheap).
- Any UI change to the `ChatListView` long-press entry point.

## Testing

No automated tests for this edge function or these views currently. Verify
manually: clear chat with all boxes unchecked (confirm identical behavior
to today — full reset). Clear with "keep level" checked (confirm level/
progress survive, messages/summary don't). Clear with "keep memories"
checked (confirm bot still references old facts on the next message, via
`[MEMORIES]` block). Clear with "keep behaviors" checked (confirm
`conversation_behaviors` rows survive and still get injected). Confirm the
`ChatListView` long-press path is completely unaffected (still full wipe,
no dialog).
