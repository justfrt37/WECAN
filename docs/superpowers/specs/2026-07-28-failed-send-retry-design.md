# Failed-Send: Per-Bubble State + Tap-to-Retry

Scope: `aiGirlfriend/Models/Message.swift`, `aiGirlfriend/ViewModels/ChatViewModel.swift`
(`send`, `sendUserVoice`, `sendUserPhoto`), `aiGirlfriend/Views/ChatView.swift`
(bubble rendering). Part of the UI/UX optimization pass.

## Problem

Optimistic UI is already in place: `send()`, `sendUserVoice()`, and
`sendUserPhoto()` all append the user's message to `messages` immediately,
before the network call resolves. But there's no failure half to that
pattern — when the subsequent `service.sendWithLocalHistory`/
`sendUserPhotoMessage` call throws (non-402 error), the catch block only
sets `errorMessage` (shown as one small red caption line below the whole
message list) and resets `isSending`/`showsTypingBubble`. The optimistically
-added bubble stays in `messages` looking exactly like a successfully sent
message — no visual failed state, no retry action. The user has to retype
the whole message manually to try again.

`pendingImagePrompt`/`pendingVoiceRequest` bubbles (from `sendImageRequest`/
`sendVoiceRequest`) already behave correctly here by accident: those two
flows only *append* the pending bubble, and the actual paid generation call
happens later on tap (`generatePendingImage`/`generatePendingVoice`) — on
failure there, the bubble simply stays in its pending state and remains
tappable, which already IS a retry. This spec only covers the three flows
that send immediately: `send`, `sendUserVoice`, `sendUserPhoto`.

## Change

### `Message` model

Add `var failed: Bool?` (defaults `nil`/absent for all existing messages,
same optional-with-default pattern as `pendingVoiceRequest`).

### `ChatViewModel`

- `send()`: capture the message's `id` at append time (currently relies on
  the default random `UUID()` from `Message.init` without capturing it —
  needs an explicit `let messageID = UUID()` like `sendUserVoice`/
  `sendUserPhoto` already do). On catch (excluding the existing
  `isInsufficientTokensError` branch, which already has its own paywall
  handling and isn't a "failed send" in the retry sense): find the message
  by `messageID` in `messages` and set `failed = true`.
- `sendUserVoice()`, `sendUserPhoto()`: same pattern — already capture
  `messageID`, just add the `failed = true` set in the catch block.
- New `retrySend(messageID: UUID)`: looks up the failed message, reads its
  `content` (and `voiceLocalPath`/`localImagePath` if present, to
  distinguish which original call to re-run), clears `failed`, and re-runs
  the same send path with the same content — reusing the existing
  `send`/`sendUserVoice`/`sendUserPhoto` machinery rather than duplicating
  the network-call logic. Removes the old failed message first (or reuses
  its id) so retry doesn't create a visible duplicate bubble.

### `ChatView` (bubble rendering)

Failed bubble gets a small error indicator (e.g. red exclamation-mark
circle, iMessage-style) next to it. Tapping the bubble (or the indicator)
calls `viewModel.retrySend(messageID:)`.

## Explicitly out of scope

- `sendImageRequest`/`sendVoiceRequest`/`generatePendingImage`/
  `generatePendingVoice` — already have working implicit retry via their
  pending-state mechanism, not touched.
- Any change to the existing `errorMessage` caption — kept as-is for
  errors that aren't tied to a specific message bubble (e.g. history load
  failures).
- Automatic retry (e.g. exponential backoff) — this is manual tap-to-retry
  only, matching the iMessage/WhatsApp pattern the user asked for.

## Testing

No automated tests for this ViewModel/View currently. Verify manually:
force a send failure (e.g. airplane mode), confirm the bubble shows the
failed indicator and the generic error caption no longer appears for this
case (or still does, if the design keeps both — decide during
implementation whether the caption is now redundant for message-specific
failures). Tap the failed bubble, confirm it retries and clears the failed
state on success. Repeat for `sendUserVoice` and `sendUserPhoto`. Confirm a
non-402 error during a normal `send()` doesn't get miscategorized as an
insufficient-tokens paywall trigger (existing `isInsufficientTokensError`
branch stays untouched, only the `else` path gets the new failed-state
behavior).
