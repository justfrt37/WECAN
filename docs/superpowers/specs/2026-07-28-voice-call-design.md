# Real-Time Voice Call — Design

## Goal
Add a real-time phone-call mode: user talks, Grok replies, ElevenLabs speaks the reply back, with barge-in (user can interrupt AI mid-speech). Separate from existing per-message "tap to hear this reply" feature, which stays as-is.

## Non-goals (this pass)
- No sentence-level streaming TTS (v1 waits for Grok's full reply, then synthesizes the whole thing as one clip — see latency tradeoff discussed during brainstorm).
- No live captions/transcript UI during the call (voice-only screen: avatar + state indicator + mute/end buttons).
- No group calls / multi-character calls.
- No change to the existing `voice-message-tts` function or its 12-token tap-to-listen charge — that path is untouched.
- No mid-call token deduction — billing settles once at call end (see Billing).

## User flow
1. Phone icon in `ChatView`'s nav bar opens `VoiceCallView` (full-screen).
2. Client calls `voice-call-start`. Server pre-checks balance (must cover a minimum ~10s: 30 tokens), auto-finalizes any orphaned `active` session for this user first (crash recovery, see Billing), creates a `call_sessions` row, returns `callSessionId`. If balance too low, call never starts — client shows an insufficient-balance state.
3. Client enters `listening`: continuous on-device `SFSpeechRecognizer` session (extends `SpeechRecognizer`'s existing pattern) with silence-based endpointing — a pause in speech ends the user's turn.
4. On turn end, client sends transcript to `voice-call-turn`. UI moves to `thinking`.
5. Server builds Grok context (character directive + memories + behaviors + recent `call_turns` for in-call continuity), calls Grok once for a full text reply (continuous natural speech — no `[PAUSE:n]` segmentation, but keeps `VOICE_TAGS_RULE` eleven_v3 emotion tags), synthesizes the whole reply via ElevenLabs, uploads the audio, inserts both turns (user + assistant) into `call_turns`, returns `{replyText, audioURL}`.
6. Client moves to `speaking`, plays the audio through `AVAudioSession(.voiceChat)` (built-in echo cancellation) while the speech recognizer keeps listening.
7. **Barge-in**: if the recognizer detects new user speech while `speaking`, playback stops immediately, state returns to `listening`, and the new speech becomes the next turn. (Because turns are only sent to Grok once a full utterance is captured, there's never an in-flight Grok/TTS call to cancel — interruption is purely a local audio-stop.)
8. Every 5s of call wall-clock time, client calls `voice-call-checkpoint` with elapsed seconds. Server records it (recovery marker, no charge) and checks affordability; if `elapsedSeconds * 3` would exceed balance, returns `{ok: false}` and the client ends the call immediately.
9. On end (user taps end-call, or a checkpoint fails), client calls `voice-call-end` with final elapsed seconds. Server charges `round(elapsedSeconds * 3)` tokens once via `charge_tokens`, marks the session `ended`, and runs one-shot memory extraction over the full `call_turns` transcript, appending results to the character's durable memories (same extraction pattern the existing chat summarization uses).

## Data model (new tables)
```sql
call_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id),
  character_id uuid not null references characters(id),
  conversation_id uuid references conversations(id),
  status text not null default 'active', -- 'active' | 'ended'
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  last_checkpoint_seconds int not null default 0,
  tokens_charged int
)

call_turns (
  id uuid primary key default gen_random_uuid(),
  call_session_id uuid not null references call_sessions(id),
  role text not null, -- 'user' | 'assistant'
  content text not null,
  audio_url text,
  created_at timestamptz not null default now()
)
```
Chat's existing `messages` table is untouched — calls never appear as chat bubbles, matching the "separate call log" decision.

## Backend (new edge functions)

**`voice-call-start`**
- Input: `{characterId, conversationId}`.
- Finds any `status='active'` session for this user (crash recovery): finalizes it using its `last_checkpoint_seconds` — charges `round(last_checkpoint_seconds * 3)` tokens, marks `ended`. This also runs before a genuinely new call, so a user can never have two active sessions.
- Checks `token_balances.balance >= 30`; if not, returns `insufficient_tokens` (402).
- Inserts new `call_sessions` row, returns `{callSessionId}`.

**`voice-call-turn`**
- Input: `{callSessionId, userTranscript}`.
- Loads `call_sessions` row → `character_id`/`conversation_id`. Fetches character + conversation + directive + memories + behaviors (reuses the existing `fetchDirectiveMemoriesBehaviors` helper from `chat/index.ts`, extracted to a shared module) plus the session's own `call_turns` so far (for in-call continuity — a call is its own short-lived conversation on top of the character's existing memory).
- Builds Grok messages: system prompt = same directive/memory/behavior assembly as normal chat, plus `VOICE_TAGS_RULE`, minus the `[PAUSE:n]` dramatic-pacing instruction (a call is continuous speech, not paced bubbles).
- Calls Grok once for the full reply text.
- Synthesizes via ElevenLabs (`elevenVoiceIdFor(role, vibe)` or the character's `voice_id` override — same resolution `voice-message-tts` uses today), uploads the mp3 to the `characters` bucket under `voices/calls/{callSessionId}/`.
- Inserts one `call_turns` row for the user's transcript and one for the assistant's reply (with `audio_url`).
- Returns `{replyText, audioURL}`. **No token charge here** — billing is time-based, settled in `voice-call-end`.

**`voice-call-checkpoint`**
- Input: `{callSessionId, elapsedSeconds}`.
- Updates `call_sessions.last_checkpoint_seconds = elapsedSeconds` (recovery marker only, no deduction).
- Reads current balance; if `elapsedSeconds * 3 > balance`, returns `{ok: false}`.
- Otherwise `{ok: true}`.

**`voice-call-end`**
- Input: `{callSessionId, actualElapsedSeconds}`.
- Charges `round(actualElapsedSeconds * 3)` tokens via `charge_tokens` (single deduction for the whole call).
- Sets `status='ended'`, `ended_at=now()`, `tokens_charged`.
- Builds the transcript from all `call_turns` for this session, runs the existing memory-extraction prompt pattern (same shape as the periodic chat summarization's memory extraction) against it, and appends any extracted durable memories to the character's stored memories for this conversation.
- Returns `{tokensCharged, newBalance}`.

## Client changes (SwiftUI)

**`CallViewModel`** (new)
- State machine: `idle → listening → thinking → speaking` (+ `ended`).
- Owns an `AVAudioSession` configured `.voiceChat` mode (built-in echo cancellation, so AI playback isn't picked up by the mic as a false interruption).
- Extends `SpeechRecognizer`'s continuous-listening pattern with silence-based endpointing to detect turn boundaries automatically (no manual stop button per turn, unlike the existing tap-to-record voice note flow).
- Drives the `voice-call-start` → loop of (`listening` → `voice-call-turn` → `speaking`) → `voice-call-end` sequence.
- 5s repeating timer while active calls `voice-call-checkpoint`; `{ok: false}` triggers immediate graceful call end.
- Barge-in: while `speaking`, keeps the recognizer running; new detected speech stops `AVAudioPlayer` playback and transitions straight to `listening` for that new utterance.

**`VoiceCallView`** (new)
- Full-screen: character avatar, pulsing/animated state indicator (listening/thinking/speaking have distinct visual states), mute button, end-call button. No text/captions.

**`ChatView.swift`**
- New phone-icon button in the nav bar, opens `VoiceCallView` as a full-screen cover.

## Cost
Time-based: 3 tokens/sec of call wall-clock time (independent of turn count), settled once at call end. A 3-minute call ≈ 540 tokens. Existing `token_balances`/`charge_tokens` infra reused as-is; no new pricing primitive beyond the per-second rate.

## Error handling
- **Grok/TTS failure mid-turn** (`voice-call-turn` errors): client shows a brief inline error state, returns to `listening` so the user can just try the turn again — no retry queue needed (this isn't persisted like a failed chat message; a call turn that failed to produce speech simply didn't happen).
- **Insufficient balance at call start**: call never begins, client shows an insufficient-balance prompt (existing pattern used elsewhere in the app for 402s).
- **Insufficient balance mid-call**: detected at the next 5s checkpoint, call ends immediately (per approved decision — no negative balances).
- **App crash / force-quit mid-call**: no `voice-call-end` ever fires. The next `voice-call-start` (whenever the user starts any call again) finds the orphaned `active` session and finalizes it using `last_checkpoint_seconds` — worst case under-bills by up to ~5s of usage, never over-bills.

## Open items for implementation phase (not blocking spec approval)
- Exact silence-timeout threshold for endpointing (starting point: reuse whatever `isFinal`/pause heuristics `SpeechRecognizer` already has, tune during testing).
- Exact visual treatment of the listening/thinking/speaking states in `VoiceCallView` (implementation-time UI detail, not an architecture decision).
- Minimum pre-call balance threshold (30 tokens ≈ 10s) — adjustable constant, not load-bearing on the design.
