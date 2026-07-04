# Bot Voice Messages — Design

## Goal
Bots can send WhatsApp-style voice-note messages, driven by Google Cloud TTS, with 28 distinct voices (7 `personality_role` × 4 `vibe` combos) across 7 languages (TR/EN/DE/FR/ES/PT/IT). Replaces the previous "read any text bubble aloud" idea — instead, user explicitly requests a voice-message reply via a dedicated button.

## Non-goals (this pass)
- No coin/gating system yet (planned later — this feature ships ungated, one tap = one voice message, no limit).
- No auto-play, no random/level-gated/AI-decided triggers.
- No re-narrating existing text bubbles (the old per-message speaker icon in `ChatBubble`/`VoicePlayer` stays as-is, unrelated feature, still falls back to on-device synth until/unless `tts` edge function exists).

## User flow
1. New button at the right end of `quickReplyRow` (`ChatView.swift:319`), fixed (not part of horizontal scroll).
2. Tap → `ChatViewModel.sendVoiceRequest()`. Disabled while sending/loading, same guard as normal send.
3. Client immediately inserts a placeholder voice bubble (pulsing waveform skeleton, "recording…" state) — reuses existing typing-indicator pattern for responsiveness.
4. Same chat generation pipeline runs (Grok, via `chat` edge function) as a normal turn, flagged `wantsVoice: true`. Grok's response additionally includes a `lang` tag — ONE of `tr/en/de/fr/es/pt/it` — describing the single language it actually replied in (matches existing "AI responds in Turkish unless asked otherwise" behavior; no multi-language generation, no separate detection pass).
5. Client calls new `tts` edge function: `{text, role: personality_role, vibe, lang}`.
6. `tts` edge function looks up voice name from a static 28-entry map (`role × vibe` → per-language Google voice name, all 7 languages pre-filled per entry), calls Google Cloud Text-to-Speech REST API (`text:synthesize`), returns raw mp3 bytes.
7. Client saves mp3 to `Application Support/VoiceMessages/{messageID}.mp3`, replaces placeholder with the real voice bubble (waveform + duration + play/pause).
8. On failure (Grok call fails, or TTS call fails/times out): placeholder bubble converts to an inline error/retry state. No text fallback is shown (voice-only, by design) — retry re-runs from step 4.

## Data model changes
- `Message.swift`: add `kind` case `.voice`; add `voiceLocalPath: String?` (filename relative to `Application Support/VoiceMessages/`), `voiceDuration: Double?`. Both optional, decode-safe default `nil` for existing local JSON (matches `LocalConversationStore`'s existing pattern for additive fields, e.g. `msgCounter`).
- `content` (reply text) is still always stored on the `Message`, even for `.voice` kind — needed so future turns' chat-history context to Grok still includes what the bot "said." UI simply never renders `content` for `.voice` messages; it renders the voice bubble instead.
- No new Supabase tables/columns. No server-side audio storage — fits the existing local-first chat architecture (`LocalConversationStore`), keeps Supabase Storage cost at zero for this feature.

## `tts` edge function (new)
- Input: `{ text: string, role: string, vibe: string, lang: string }`
- Static voice map (own file, e.g. `supabase/functions/tts/voiceMap.ts`): 28 keys (`${role}_${vibe}`), each a 7-entry object keyed by lang → Google voice name (e.g. `tr-TR-Wavenet-C`). Filling in actual voice names per combo is implementation-time data entry, not an architecture decision — pick plausible fits per vibe (e.g. "Energetic" vibes → brighter-sounding voices) at build time, adjustable later without any client change.
- Fallback within the map: if a specific role×vibe is somehow missing (shouldn't happen once populated), fall back to a per-language default voice.
- Calls `https://texttospeech.googleapis.com/v1/text:synthesize` with an API key stored as a Supabase edge function secret (`GOOGLE_TTS_API_KEY`), `audioConfig.audioEncoding: "MP3"`.
- Returns audio bytes with `Content-Type: audio/mpeg` on success; non-200 / empty body signals failure to the client (existing `TTSService.synthesize` in `VoicePlayer.swift` already expects exactly this contract).

## `chat` edge function changes
- New optional request field `wantsVoice: boolean`.
- When true, prompt additionally instructs Grok to also emit a `lang` field (one of the 7 codes) reflecting the language of its own reply, returned alongside the existing reply text in the same call — no extra model call, no separate language-detection library.

## Client changes
- `ChatViewModel`: new `sendVoiceRequest()` method, parallel to existing `send()`. Reuses `sendWithLocalHistory`-style history assembly, adds `wantsVoice: true` to the request, handles the returned `{reply, lang}`, then calls the new `TTSService`-equivalent for `tts` (extending `VoicePlayer.swift`'s existing `TTSService` struct with the `role/vibe/lang` params it doesn't currently send).
- `ChatView.swift`: button next to `quickReplyRow`; new `VoiceMessageBubble` view (waveform bar + duration label + play/pause, tap plays via the same `AVAudioPlayer` approach `VoicePlayer` already uses) rendered in place of `ChatBubble`'s text content when `message.kind == .voice`.
- `LocalConversationStore`: no logic changes beyond the additive `Message` fields already being handled by its existing `Codable` decode-with-defaults pattern.

## Cost
Bounded by explicit user taps only (no auto-play, no gating yet). Google Neural2/WaveNet tier ≈ $16/1M chars; typical bot reply ≈100–150 chars ⇒ fractions of a cent per tap. Estimated **~$0.20–0.25 per active user per month** even at generous usage (15–20% of turns as voice requests). Real driver is DAU × tap-rate, not language count — the 7-language map is a one-time setup cost, not a running cost multiplier.

## Open items for implementation phase (not blocking spec approval)
- Actual Google voice name selections for all 28×7 = 196 map entries.
- Exact waveform bubble visual treatment (static generated bar vs. real amplitude data — static is sufficient and simplest, per architecture above).
- `GOOGLE_TTS_API_KEY` provisioning (user has a Firebase/GCP account already; needs Cloud Text-to-Speech API enabled + key created, see prior conversation).
