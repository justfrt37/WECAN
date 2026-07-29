# Voice Call Migration to ElevenLabs Agents — Design

## Context

The current voice call feature (see `2026-07-28-voice-call-design.md`) is a hand-rolled turn-based pipeline: on-device `SFSpeechRecognizer` → full transcript sent to `voice-call-turn` → Grok generates a full text reply → ElevenLabs' plain REST TTS (`eleven_v3`, for emotion tags) renders the entire audio clip → client downloads and plays it. Barge-in is a local poll loop watching the recognizer's transcript while `speaking`.

In practice this is slow (~15s per turn observed) and produces overly long replies (~40s audio clips), because every step blocks on the previous one fully completing, and there was no length constraint on Grok's output. A partial fix (shorter replies, non-blocking storage writes) shipped, but the sequential-blocking architecture has a hard floor: `eleven_v3` itself cannot do real-time synthesis — ElevenLabs' own docs state Flash v2.5 (~75ms) is required for real-time/Agents use, and v3's larger model/higher-fidelity codec make it unsuitable for streaming low-latency generation.

Decision: drop the `eleven_v3` audio-tag requirement, move to ElevenLabs' Agents platform (Flash v2.5) for genuine real-time duplex voice, and replace inline `[tags]` emotional expression with `voice_settings` tuning + prompt-level punctuation/word-choice guidance (Flash reads emotional cues from the text itself, not bracket tags).

## Goal

Replace the REST turn-loop with an ElevenLabs Agents-based real-time call: sub-second turn latency, native barge-in/interruption, same per-character voice selection, same token billing model, same memory-extraction-on-hangup behavior.

## Non-goals (this pass)

- No per-turn dynamic emotion (e.g. Grok emitting an emotion label that changes `voice_settings` mid-call). Static per-`personality_role` `voice_settings` presets only — revisit only if that proves insufficient after real testing.
- No change to `voice-message-tts` (the separate per-message "tap to hear this reply" feature) — untouched, still REST + whatever model it currently uses.
- No group calls / multi-character calls.
- No change to the token pricing model (`3 tokens/second`) or the checkpoint/end billing mechanics — only how elapsed time is measured (still client wall-clock) changes not at all.
- Text-fallback input (typed message during a call, shipped as a stopgap for mic-less testing) is kept, but whether the ElevenLabs SDK supports injecting text into an active session is **unverified** — see Open Questions.

## Architecture

- **One ElevenLabs Agent**, created once (dashboard or API), configured with:
  - TTS model: Flash v2.5.
  - Custom LLM: webhook mode, pointed at a new edge function `voice-call-llm-webhook`, implementing the OpenAI-compatible `/v1/chat/completions` SSE contract ElevenLabs requires for custom LLMs.
  - No agent-level system prompt content — the webhook supplies the full system prompt per-request (see below), since it's per-character/per-relationship-state and can't be static on the Agent config.
- **Per-call overrides**, sent by the client at conversation-initiation via `conversation_initiation_client_data`:
  - `dynamic_variables`: `{ callSessionId, characterId }` — lets the webhook look up which character/session this turn belongs to (ElevenLabs' custom-LLM webhook contract doesn't otherwise carry this).
  - `conversation_config_override.tts.voice_id`: resolved exactly as today — `character.voice_id ?? elevenVoiceIdFor(personalityRole, vibe)` (`_shared/elevenVoiceMap.ts`, unchanged).
  - `conversation_config_override.tts.voice_settings`: `{stability, style}`, looked up from a new static per-`personality_role` preset table (7 entries, sibling to `elevenVoiceMap`).
- **Client**: `CallViewModel` rewritten around the ElevenLabs Conversational AI Swift SDK's `Conversation` session, replacing `SpeechRecognizer` + `CallService`'s turn-loop + the hand-rolled barge-in poll. The SDK owns mic capture, ASR, TTS playback, and interruption. `SpeechRecognizer` itself is untouched and keeps serving `ChatView`'s separate tap-to-record voice notes.

## Data Flow

1. User taps call → `CallViewModel.startCall()` → `CallService.start()` calls `voice-call-start` (extended, not replaced):
   - Same pre-checks as today: finalize any orphaned `active` session, verify balance ≥ `MIN_START_BALANCE`, create the `call_sessions` row.
   - New: resolves `voice_id` + `voice_settings` for this character, fetches a short-lived ElevenLabs conversation token server-side (API key never reaches the client), returns `{callSessionId, conversationToken, voiceId, voiceSettings}`.
2. Client opens an ElevenLabs SDK session with the token, `dynamic_variables`, and `conversation_config_override` from step 1.
3. From here the SDK owns the duplex audio loop: mic → ElevenLabs ASR → turn-complete detection → Agent calls `voice-call-llm-webhook` (their infra initiates the HTTP call to our server) with the OpenAI-format running chat history → webhook:
   - Resolves `callSessionId` → `character_id`, `conversation_id` from `call_sessions`.
   - Fetches directive/memories/behaviors exactly as `voice-call-turn` does today (reuses `directiveHelpers.ts` unchanged).
   - Builds the system prompt: directive + memories + behaviors + a new brevity/punctuation-emotion instruction (replaces `VOICE_TAGS_RULE`, which is deleted for calls).
   - Calls Grok with `stream: true`, reformats the stream as OpenAI-compatible SSE back to the Agent.
   - Fire-and-forgets an insert into `call_turns` (same shape as today, via `EdgeRuntime.waitUntil`) so `voice-call-end`'s memory extraction needs no changes.
   - Agent's Flash TTS speaks the streamed reply back over the same WebSocket; SDK plays it and handles barge-in natively if the user talks over it.
4. Unchanged: client runs its own 5s `voice-call-checkpoint` timer off wall-clock elapsed time, ends the call early if projected cost would exceed balance.
5. Hangup → client closes the SDK session → calls `voice-call-end` (unchanged): charges `round(elapsedSeconds * 3)` tokens, marks the session `ended`, runs memory extraction over `call_turns`.

## Components Changed

| Component | Change |
|---|---|
| `voice-call-turn` (edge fn) | Deleted, replaced by `voice-call-llm-webhook`. |
| `voice-call-llm-webhook` (edge fn) | New. OpenAI-compatible SSE contract; reuses `directiveHelpers.ts`, `elevenVoiceMap.ts`. |
| `voice-call-start` (edge fn) | Extended: adds ElevenLabs conversation token fetch + voice_id/voice_settings resolution to the response. |
| `voice-call-checkpoint`, `voice-call-end` | Unchanged. |
| `_shared/elevenVoiceMap.ts` | Unchanged — still the voice_id source of truth. |
| New: `_shared/elevenVoiceSettings.ts` (or similar) | Static `{stability, style}` preset per `personality_role`. |
| `SpeechRecognizer.swift` | Unchanged — no longer used by calls, still used by `ChatView` voice notes. |
| `CallService.swift` | Rewritten: `start()`/`end()`/`checkpoint()` keep their edge-function calls; `sendTurn()` deleted (no longer client-driven — the Agent calls the webhook directly). |
| `CallViewModel.swift` | Rewritten around the ElevenLabs SDK's `Conversation` session. Barge-in poll loop, `runListenTurn`, `speak()` deleted. Checkpoint timer logic kept as-is. |
| `VoiceCallView.swift` | State labels/DEBUG overlay adapted to the SDK's connection/speaking-state callbacks instead of today's discrete STT/LLM/TTS log lines. Elapsed-time UI (already built) unchanged. Text-fallback field kept, pending the Open Question below. |

## Error Handling

- ElevenLabs token fetch or WebSocket connection failure at start → `CallState.ended(.error)`, same UX as today's `voice-call-start` failure path.
- `voice-call-llm-webhook` failure (Grok down/timeout) → hard timeout on the webhook so it fails fast; Agent surfaces this as a connection hiccup to the client rather than hanging the turn indefinitely.
- Insufficient tokens: unchanged — pre-check at start (`MIN_START_BALANCE`), checkpoint-driven mid-call cutoff.

## Testing

- No unit-testable surface for the WebSocket audio path itself; verification is manual. Simulator mic caveats from the current build (HAL device drop / `AVAudioEngine` flakiness on beta macOS) still apply since the SDK still needs real audio input — real device remains the reliable test path.
- DEBUG overlay rewired from today's `STT understood / LLM received / LLM answered / API responded with sound / Sound played` log lines to whatever state/transcript callbacks the SDK exposes (connection state, agent speaking/listening, errors).

## Open Questions (must resolve during implementation, before considering this done)

1. **Text-fallback input**: does the ElevenLabs Swift SDK support injecting a text message into an active voice session? If not, need either a small custom addition alongside the SDK session, or the feature is temporarily dropped for the Agents path.
2. **Custom-LLM webhook exact request/response shape**: confirmed OpenAI-compatible `/v1/chat/completions` with SSE streaming in principle; exact field-level contract (how `dynamic_variables` actually arrive in the webhook request, whether ElevenLabs injects its own system message that needs to be overridden vs. appended) needs verification against ElevenLabs' current docs/an actual test call before writing `voice-call-llm-webhook`.
3. **xAI/Grok streaming support**: existing `callGrok()` in the codebase is non-streaming (`voice-call-turn`, `voice-call-end`, `chat`). Need to confirm `stream: true` works against `api.x.ai/v1/chat/completions` and write a new streaming variant.
4. **Conversation token fetch**: exact ElevenLabs endpoint/auth flow for server-side short-lived token issuance (vs. a full signed URL) needs confirming against current docs when implementing `voice-call-start`'s extension.
