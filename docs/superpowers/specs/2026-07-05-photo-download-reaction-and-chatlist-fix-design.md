# Photo download + private-photo reaction, and chat-list ordering fix

Date: 2026-07-05

## Part 1: Photo download + private-photo complaint

### Goal

Let the user download a character's photo from the fullscreen chat viewer. If the
downloaded photo was generated as "private"/intimate, the character reacts with a
short, natural, in-character complaint (e.g. "you're not going to share that with
anyone, right?") — reasoned by Grok per-turn, not a hardcoded string.

### 1. Classify photos as private at generation time

`supabase/functions/chat-image/index.ts` already composes a detailed photo-director
prompt (SUBJECT/OUTFIT/POSE/LOCATION fields) before calling Grok Imagine. Add one
more short Grok **text** call right after that prompt is composed: give it the
composed prompt text, ask for a single yes/no on whether the described photo reads
as private/intimate/revealing. No vision call needed — reasons over the text
already in memory, not the rendered pixels.

New migration (`supabase/migrations/005_generated_photos_private_flag.sql`):

```sql
alter table generated_photos
  add column is_private boolean not null default false,
  add column reacted boolean not null default false;
```

Store the classification result (`is_private`) on the existing insert into
`generated_photos` (`chat-image/index.ts` ~line 415). `reacted` starts false and
flips to true the first time the download-reaction fires for that row (see Part
1.3) — the reaction should only happen once per photo, not on every re-download.

### 2. Download button in the fullscreen viewer

`ChatView.swift`'s `FullscreenImageView` (private struct, ~line 621) gets a second
button next to the existing X close button: a download icon.

- Uses the already-cached `UIImage` (`ImageCache.shared.image(for:)` — already
  synchronously available since the photo is already on screen).
- Saves via `PHPhotoLibrary` (`performChanges` with
  `PHAssetChangeRequest.creationRequestForAsset(from:)`).
- Add `NSPhotoLibraryAddUsageDescription` to `project.pbxproj` under both build
  configs (Debug/Release), same pattern as the existing
  `INFOPLIST_KEY_NSMicrophoneUsageDescription` /
  `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` keys.
- On success: brief confirmation (toast-style, matches existing lightweight UI
  patterns in the app — no new dependency). On permission denial: simple inline
  message: no elaborate Settings deep-link, out of scope.
- After a successful save, if this photo turns out to be a "generated" photo (i.e.
  came from `chat-image`, has a `generated_photos` row), kick off the reaction
  check (Part 1.3). Photos that aren't tracked in `generated_photos` (e.g. static
  catalog/profile photos) just download silently — no reaction path for those.

### 3. Reaction on download — new `photoDownloadReaction` mode on `chat` function

Client (`ChatViewModel`, new method `reactToPrivateDownload(imageURL: URL)`) calls
the existing `chat` edge function with:

```json
{
  "photoDownloadReaction": true,
  "photoURL": "<the downloaded photo's url>",
  "characterId": "...",
  "systemPrompt": "...",
  "clientHistory": [...],
  "localSummary": "...",
  "level": <clientLevel>
}
```

No `userMessage` this turn — same shape used by `voiceChat`/`imageReactionChat`
today (`chat/index.ts`).

Server-side (`chat/index.ts`):

1. Look up the `generated_photos` row by `url` + `user_id = uid`.
2. If no row found, `is_private` is false, or `reacted` is already true →
   return `{ reply: null }` immediately. No Grok call, no side effects.
3. Otherwise build the system prompt exactly as the normal flow does (character
   directive, personality role, relationship level, `ex_history`, memories,
   behaviors), append a new `PHOTO_DOWNLOAD_REACTION_RULE`:

   > Instruct Grok that the user just downloaded a private/intimate photo of the
   > character to their device. Grok should write ONE short, natural,
   > in-character reaction — a cute, natural complaint/tease about it (e.g.
   > concern about the photo being shared, mock-offended, playfully flustered —
   > tone depends on the character's personality/role/relationship level). Must
   > reason this out itself; never reuse a fixed template sentence. Same
   > `VARIATION_RULE`-style "never robotic, never identical twice" framing as
   > existing rules.

4. Append `languageDirective(detectReplyLanguage(...))` — reusing the existing
   detection, but since there's no new `userMessage` this turn, detect from
   `clientHistory`'s recent user messages only.
5. Call Grok once with this system prompt (no history turn needed beyond
   context), get the reply, mark `reacted = true` on the `generated_photos` row,
   return `{ reply }`.

Client: on a non-null `reply`, appends it as a new assistant `Message` directly
into `LocalConversationStore` + `store.chatCache` (same local-injection pattern
`NotificationDelegate` already uses for jealousy/ghosted/liked bait) — bumps
`store.conversationsVersion` (see Part 2) so `ChatListView` picks it up if open.
Explicitly does NOT count as a real conversation turn: no XP/relationship-level
effect, no user message shown, no `LANGUAGE_RULE`-driven turn end validation
beyond what's described above.

### Out of scope (confirmed with user)

- Gallery's "Your Photos" grid does not get a fullscreen viewer or download
  button in this pass — only the existing chat-bubble fullscreen viewer.
- No Settings-deep-link flow for denied photo-library permission.
- No UI difference for non-private photo downloads beyond the save confirmation
  (no reaction message).

## Part 2: Chat-list ordering / realtime bug

### Root cause

`ChatListView.swift`:

- `messagesSection` renders `ForEach(filtered)` with **no sorting at all** —
  `items` are in whatever order `service.fetchConversations()` returned, not
  ordered by recency. "Newest on top" was never actually implemented.
- The only refresh trigger is `.onChange(of: store.typingCharacterIDs)` (line
  60), which covers the ordinary send/receive typing flicker but not
  out-of-band message injection — specifically `NotificationDelegate`'s
  jealousy/ghosted/liked-bait injection, and now this new download-reaction
  injection, neither of which toggle typing state. If a message like that lands
  while `ChatListView` is open, the row can go stale/unordered until something
  else forces a reload (e.g. leaving and re-entering the tab).

### Fix (client-only, no backend change)

1. **Sort by recency.** In `ChatListView.load()`, after building `items`, sort
   descending by the actual last-message timestamp
   (`displayMessages.last?.createdAt`, falling back to `conv.updatedAt` when
   there's no local message) before assigning to `items`.
2. **New reactive trigger.** Add `@Observable var conversationsVersion: Int = 0`
   to `CharacterStore`. Bump it at every point a message gets injected into
   `LocalConversationStore` outside the normal send-flow return path:
   `NotificationDelegate`'s injection point, and the new
   `reactToPrivateDownload` injection from Part 1.3. `ChatListView` adds
   `.onChange(of: store.conversationsVersion) { Task { await load() } }`
   alongside the existing typing-based trigger.

This closes the gap where a background-injected message lands while the chat
list is open and nothing tells it to reload/reorder.
