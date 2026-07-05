# Chat image-generation mode — design

Date: 2026-07-05

## Problem

`quickReplyRow` currently shows 4 static preset text chips ("Hey 👋", "What's up? 💕", …)
plus one waveform icon that arms "voice mode" (bot replies as a tap-to-play voice note
instead of text). The chips add little value and there's no way to ask the bot for a
*specific* photo — the existing photo flow (`ChatViewModel.photoRequested()`) only fires on
keyword match and picks a random pre-set image from `character.chatPhotos`, ignoring what
the user actually asked for.

## Goal

Replace the chip row with two mode-toggle buttons — "Send me a voice" and "Send me a
photo" — mirroring each other. Photo mode generates a real image via xAI's Grok image API
(`grok-imagine-image`, already used by `create-character`'s `generateImageOnly` mode) from
the user's own typed description, instead of picking from a static pool.

## 1. Backend — new `chat-image` edge function

New file `supabase/functions/chat-image/index.ts`, structurally parallel to
`create-character`'s image-generation path (same `XAI_IMAGE_URL`/`IMAGE_MODEL` constants,
same `fetchGeneratedImageBytes`/`uploadGeneratedImage` helpers, duplicated rather than
shared — matches this codebase's existing convention of self-contained edge functions with
no shared runtime module).

**Request:** `{ characterId: string, prompt: string }`, `Authorization: Bearer <JWT>`.

**Auth:** rejects with 401 if the JWT is missing/unparseable (same strict gate as
`generateImageOnly`, since this is a real per-call cost).

**Flow:**
1. Fetch the `characters` row (service role) for `characterId`: `name`, `builder_selections`,
   `category`, `profession`, `tagline`.
2. Build the image prompt:
   - If `builder_selections` has appearance fields (user-created characters), reuse
     `create-character`'s `buildImagePrompt`-style appearance clause (hairstyle/hair color/
     eye shape/eye color/nose shape/skin tone/category) so the generated photo still looks
     like the same character.
   - Otherwise (catalog characters have no `builder_selections`), fall back to a loose style
     cue built from `category`/`profession`/`tagline`. No guaranteed visual consistency for
     catalog bots — same limitation the character-creation flow already has for anything
     without recorded appearance fields.
   - Append the user's own free-form request as the scene/action/pose description.
3. Call `POST /v1/images/generations` (`grok-imagine-image`, resolution `2k`), upload result
   bytes to Storage bucket `characters`, path `generated/<uuid>.png` (same bucket/folder
   `create-character` already uses).
4. Get-or-create the `(user, character)` conversation row — reuse the same lookup pattern
   `add-character-note/index.ts` already has — to obtain `conversation_id`.
5. Insert `{ conversation_id, url }` into new table `generated_photos` (service role).
6. Return `{ url }`. On any failure: `{ error: "image_generation_failed" }`, HTTP 502 — no
   fallback photo is substituted (client shows an error, per product decision).

## 2. "Let Grok decide" caption mechanic

`chat/index.ts` gains a new request flag `imageReactionChat: true` (same shape as the
existing `voiceChat` flag). When present, it appends a new `IMAGE_CAPTION_RULE` to the
system prompt:

> "You just sent the photo the user asked for. If you naturally want to react afterward,
> write a short in-character line. If you don't want to send a reaction, reply with EXACTLY
> `[[no_caption]]` and nothing else."

This reuses the existing `[[marker]]` convention already in the codebase (`[[photo]]`).
The client checks for that literal (trimmed) string and skips the follow-up bubble when
present.

## 3. Client data flow — `ChatViewModel.sendImageRequest()`

New method, structurally parallel to `sendVoiceRequest()`:

1. Guard non-empty input / not already sending.
2. Append the user's message (their photo description), clear input, disarm `isImageArmed`.
3. Set `isSending = true`, `isSendingImageReply = true` (new flag — shows a dedicated
   pending indicator instead of the 3-dot typing bubble, since there's no text reply yet at
   this point, just image generation in flight).
4. Call `ChatService.generateChatImage(character:, prompt:)` → new method hitting the
   `chat-image` function.
   - **On failure:** `errorMessage` set, `isSendingImageReply = false`, `isSending = false`,
     return. No message appended.
   - **On success:** append `Message(role: .assistant, content: "", imageURL: url)`
     (identical shape to today's random-photo message), clear `isSendingImageReply`.
5. Immediately request the optional caption: call the existing
   `service.sendWithLocalHistory(..., imageReactionChat: true)` (same call `send()`/
   `sendVoiceRequest()` already make, just with the new flag) to get `result.reply`, showing
   the normal typing bubble during the wait.
6. If `result.reply.trimmingCharacters(in: .whitespacesAndNewlines) != "[[no_caption]]"`,
   append `Message(role: .assistant, content: result.reply)` after the usual
   `TypingTiming`-based delay (so it visibly lands *after* the photo, never simultaneously).
7. Call `applyPostReplyEffects(gotPhoto: url, stored: stored)` — reuses the existing
   `photoGainFraction` XP path unchanged.

New `ChatViewModel` state: `isImageArmed: Bool = false`, `isSendingImageReply: Bool = false`.

## 4. UI — `quickReplyRow` replacement

`ChatView.quickReplies` array and its chip `ForEach` are deleted. `quickReplyRow` becomes
two capsule buttons filling the row:

- **"Send me a voice"** — waveform icon, toggles `isVoiceArmed`.
- **"Send me a photo"** — camera icon, toggles `isImageArmed`.

Toggling one clears the other (mutually exclusive — the send button can only route one
way). Armed state uses the same pink-highlight treatment `isVoiceArmed` already has.

`inputBar`'s `TextField` prompt text becomes conditional: `"Describe the photo…"` while
`isImageArmed`, otherwise unchanged (`"Message…"`).

The send button's action becomes a three-way branch:
```
if viewModel.isImageArmed { viewModel.sendImageRequest() }
else if viewModel.isVoiceArmed { viewModel.sendVoiceRequest() }
else { viewModel.send() }
```

`messagesList`'s typing-bubble branch gains a third case: a new private `ImagePendingIndicator`
view (same file, same pattern as the existing `VoicePendingIndicator` — distinct pulsing
silhouette, e.g. a camera/sparkle capsule) shown when `viewModel.isSendingImageReply` is true.

## 5. Private "Your Photos" storage

`characters.gallery_urls` is a single column on the (often shared/catalog) character row —
appending a user's generated photo there would leak it to every other user chatting with
that same catalog bot. Instead:

**New migration `004_generated_photos.sql`:**
```sql
create table generated_photos (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references conversations(id) on delete cascade,
  url text not null,
  created_at timestamptz not null default now()
);

alter table generated_photos enable row level security;

create policy "select own generated photos" on generated_photos
  for select using (
    conversation_id in (select id from conversations where user_id = auth.uid())
  );
```
No INSERT/UPDATE/DELETE policy — writes only ever happen via the `chat-image` edge
function's service-role client, matching `memories`/`conversation_behaviors`'s
service-role-write convention, but with RLS added (unlike those two) since this table needs
direct client-side SELECT for the Gallery view below.

**`GalleryView.swift`** gains a new unlocked "Your Photos" section, populated from a new
`GeneratedPhotoService.fetch(characterId:) async throws -> [URL]` (plain Supabase REST GET
against `generated_photos` joined through `conversations`, using the user's JWT so RLS
scopes it automatically — same request pattern `CharacterService` already uses). Rendered
unblurred, above the existing locked/blurred grid; hidden entirely when empty. This section
is never shown anywhere else (not Discover, not Explore, not Likes) — those views don't
read `galleryURLs`/this new table at all today and this change doesn't add that.

## Non-goals (explicitly deferred, per discussion)

- No daily/PRO cost gating on generation — revisit once real usage data exists.
- No fallback-to-pool-photo on generation failure — user sees an error instead.
- Not merged into `character.chatPhotos` (the random-photo-request pool) — generated photos
  stay in the new private table only.

## Files touched

- New: `supabase/functions/chat-image/index.ts`
- New: `supabase/migrations/004_generated_photos.sql`
- Edit: `supabase/functions/chat/index.ts` (`imageReactionChat` flag + `IMAGE_CAPTION_RULE`)
- Edit: `aiGirlfriend/Services/ChatService.swift` (`generateChatImage`, `sendWithLocalHistory`
  gains `imageReactionChat` param)
- New: `aiGirlfriend/Services/GeneratedPhotoService.swift`
- Edit: `aiGirlfriend/ViewModels/ChatViewModel.swift` (`isImageArmed`, `isSendingImageReply`,
  `sendImageRequest()`)
- Edit: `aiGirlfriend/Views/ChatView.swift` (`quickReplyRow` rewrite, send-button branch,
  `ImagePendingIndicator`, input placeholder)
- Edit: `aiGirlfriend/Views/GalleryView.swift` ("Your Photos" section)
