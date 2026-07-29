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

Verified against the actual ElevenLabs Swift SDK source (`github.com/elevenlabs/elevenlabs-swift-sdk`, v3.2.2) and REST docs — see Components Changed for exact types/endpoints.

- **One ElevenLabs Agent**, created once (dashboard or API), configured with:
  - TTS model: Flash v2.5.
  - Custom LLM: webhook mode, pointed at a new edge function `voice-call-llm-webhook`, implementing the OpenAI-compatible `/v1/chat/completions` SSE contract ElevenLabs requires for custom LLMs.
  - No static agent-level system prompt — overridden per-call (see below), since it's per-character/per-relationship-state.
- **Per-call overrides**, computed server-side in `voice-call-start` and passed by the client into `ConversationConfig` when starting the SDK session:
  - `agentOverrides.prompt`: the full system prompt (directive + memories + behaviors + brevity/punctuation-emotion instruction), built **once** at call start — not re-fetched per turn. Memories/behaviors don't change mid-call, so this avoids a DB round-trip on every turn.
  - `ttsOverrides.voiceId`: resolved exactly as today — `character.voice_id ?? elevenVoiceIdFor(personalityRole, vibe)` (`_shared/elevenVoiceMap.ts`, unchanged).
  - `ttsOverrides.stability`: looked up from a new static per-`personality_role` preset table. **Note:** the SDK's `TTSOverrides` only exposes `voiceId`, `stability`, `speed`, `similarityBoost` — there is no `style`/exaggeration knob at the override level, unlike the plain TTS API.
  - `customLlmExtraBody: ["callSessionId": callSessionId]`: the only thing the webhook needs per-turn — everything else it needs (character/system prompt) already arrived via `agentOverrides.prompt` as part of the `messages` array ElevenLabs forwards to it.
- **Client**: `CallViewModel` rewritten around `ElevenLabs.startConversation(conversationToken:config:)`, returning a `Conversation` (`ObservableObject`), replacing `SpeechRecognizer` + `CallService`'s turn-loop + the hand-rolled barge-in poll. The SDK (built on LiveKit WebRTC) owns mic capture, ASR, TTS playback, and interruption. `SpeechRecognizer` itself is untouched and keeps serving `ChatView`'s separate tap-to-record voice notes.

## Data Flow

1. User taps call → `CallViewModel.startCall()` → `CallService.start()` calls `voice-call-start` (extended, not replaced):
   - Same pre-checks as today: finalize any orphaned `active` session, verify balance ≥ `MIN_START_BALANCE`, create the `call_sessions` row.
   - New: fetches directive/memories/behaviors (reuses `directiveHelpers.ts` unchanged) and builds the full system prompt once; resolves `voice_id` + `stability` preset; calls `GET https://api.elevenlabs.io/v1/convai/conversation/token?agent_id=<AGENT_ID>` (header `xi-api-key`) to get a short-lived `{token, conversation_id}` (API key never reaches the client). Returns `{callSessionId, conversationToken, systemPrompt, voiceId, stability}`.
2. Client calls `ElevenLabs.startConversation(conversationToken:, config: ConversationConfig(agentOverrides: .init(prompt: systemPrompt), ttsOverrides: .init(voiceId:, stability:), customLlmExtraBody: ["callSessionId": callSessionId], onAgentStateChange:, onUserTranscript:, onAgentResponse:, onDisconnect:, onError:))`.
3. From here the SDK owns the duplex audio loop over WebRTC: mic → ElevenLabs ASR → turn-complete detection → Agent calls `voice-call-llm-webhook` (their infra initiates the HTTP call to our server) with the OpenAI-format `messages` array (already containing the correct system prompt via the override) plus `elevenlabs_extra_body: {callSessionId}` → webhook:
   - Reads `elevenlabs_extra_body.callSessionId` from the request body.
   - Calls Grok with `stream: true` using the `messages` array as-is (no DB lookup needed — the system prompt already arrived correct).
   - Reformats Grok's stream as OpenAI-compatible SSE (`data: {...}\n\n` chunks, `data: [DONE]\n\n` terminator) back to the Agent.
   - Fire-and-forgets an insert into `call_turns` (same shape as today, via `EdgeRuntime.waitUntil`) so `voice-call-end`'s memory extraction needs no changes.
   - Agent's Flash TTS speaks the streamed reply back over the same WebRTC connection; SDK plays it and handles barge-in natively if the user talks over it (`onInterruption` callback).
4. Unchanged: client runs its own 5s `voice-call-checkpoint` timer off wall-clock elapsed time, ends the call early if projected cost would exceed balance.
5. Hangup → client calls `conversation.endConversation()` → calls `voice-call-end` (unchanged): charges `round(elapsedSeconds * 3)` tokens, marks the session `ended`, runs memory extraction over `call_turns`.

Text fallback: `conversation.sendMessage(_ text: String) async throws` — confirmed to exist on the SDK's `Conversation` class, sends a text message into the active session same as a spoken turn would. Resolves Open Question 1 below.

## Components Changed

| Component | Change |
|---|---|
| `voice-call-turn` (edge fn) | Deleted, replaced by `voice-call-llm-webhook`. |
| `voice-call-llm-webhook` (edge fn) | New. OpenAI-compatible `/v1/chat/completions` SSE contract, streams Grok, writes `call_turns`. No directive/memory lookup — receives the system prompt pre-built via the `messages` array. |
| `voice-call-start` (edge fn) | Extended: builds the full system prompt (moved here from the old per-turn `voice-call-turn`), resolves `voice_id`/`stability`, fetches an ElevenLabs conversation token via `GET /v1/convai/conversation/token`. |
| `voice-call-checkpoint`, `voice-call-end` | Unchanged. |
| `_shared/elevenVoiceMap.ts` | Unchanged — still the voice_id source of truth. |
| New: `_shared/elevenVoiceSettings.ts` | Static `{stability}` preset per `personality_role` (no `style` — not exposed by the SDK's `TTSOverrides`). |
| `SpeechRecognizer.swift` | Unchanged — no longer used by calls, still used by `ChatView` voice notes. |
| `CallService.swift` | Rewritten: `start()` now also returns `conversationToken`/`systemPrompt`/`voiceId`/`stability`; `end()`/`checkpoint()` keep their edge-function calls unchanged; `sendTurn()` deleted (no longer client-driven — the Agent calls the webhook directly). |
| `CallViewModel.swift` | Rewritten around `ElevenLabs.startConversation(conversationToken:config:)` and the returned `Conversation`. Barge-in poll loop, `runListenTurn`, `speak()`, `SpeechRecognizer` usage all deleted. Checkpoint timer logic kept as-is. Text input now calls `conversation.sendMessage(_:)`. |
| `VoiceCallView.swift` | State labels/DEBUG overlay adapted to `conversation.agentState` (`.listening`/`.speaking`/`.thinking`) and `onUserTranscript`/`onAgentResponse`/`onError` callbacks instead of today's discrete STT/LLM/TTS log lines. Elapsed-time UI (already built) unchanged. |
| `Package.swift` / Xcode project | New SPM dependency: `https://github.com/elevenlabs/elevenlabs-swift-sdk.git`, product `ElevenLabs` (pulls in LiveKit transitively). |

## Error Handling

- ElevenLabs token fetch or WebSocket connection failure at start → `CallState.ended(.error)`, same UX as today's `voice-call-start` failure path.
- `voice-call-llm-webhook` failure (Grok down/timeout) → hard timeout on the webhook so it fails fast; Agent surfaces this as a connection hiccup to the client rather than hanging the turn indefinitely.
- Insufficient tokens: unchanged — pre-check at start (`MIN_START_BALANCE`), checkpoint-driven mid-call cutoff.

## Testing

- No unit-testable surface for the WebSocket audio path itself; verification is manual. Simulator mic caveats from the current build (HAL device drop / `AVAudioEngine` flakiness on beta macOS) still apply since the SDK still needs real audio input — real device remains the reliable test path.
- DEBUG overlay rewired from today's `STT understood / LLM received / LLM answered / API responded with sound / Sound played` log lines to whatever state/transcript callbacks the SDK exposes (connection state, agent speaking/listening, errors).

## Resolved Questions

1. ~~Text-fallback input~~ — **resolved**: `Conversation.sendMessage(_ text: String) async throws` exists on the SDK, confirmed in source. Kept.
2. ~~Custom-LLM webhook exact request/response shape~~ — **resolved**: request body is `{messages, model, temperature, max_tokens, stream, elevenlabs_extra_body}` (the last only present if the client set `customLlmExtraBody`); `messages` includes whatever system message the Agent was configured/overridden with. Response: `Content-Type: text/event-stream`, OpenAI-format chunks (`data: {...}\n\n`), terminated with `data: [DONE]\n\n`.
3. ~~Conversation token fetch~~ — **resolved**: `GET https://api.elevenlabs.io/v1/convai/conversation/token?agent_id=<AGENT_ID>` with header `xi-api-key: <key>`, returns `{token, conversation_id}`.

## Open Questions (must resolve during implementation, before considering this done)

1. **xAI/Grok streaming support**: existing `callGrok()` in the codebase is non-streaming (`voice-call-turn`, `voice-call-end`, `chat`). Need to confirm `stream: true` works against `api.x.ai/v1/chat/completions` and write a new streaming variant. First task in the implementation plan is a live curl smoke test against this before writing any webhook code.
2. **ElevenLabs Agent provisioning**: whether the Agent itself (Flash v2.5, custom-LLM webhook URL, no static prompt) is created via the ElevenLabs dashboard by hand or via their Agent-creation API — dashboard is simpler for a single one-time setup and is the assumed path; needs the resulting `agent_id` recorded as a Supabase secret (`ELEVENLABS_AGENT_ID`) for `voice-call-start` to use.
