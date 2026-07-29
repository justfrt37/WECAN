# Voice Call Migration to ElevenLabs Agents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current hand-rolled REST voice-call pipeline (on-device STT → Grok → ElevenLabs `eleven_v3` REST TTS, ~15s/turn) with ElevenLabs Agents (Flash v2.5) for real-time (~sub-second) duplex voice calls, dropping v3 audio tags in favor of `voice_settings` tuning + prompt-level emotional phrasing.

**Architecture:** One ElevenLabs Agent (Flash v2.5, custom-LLM webhook pointed at a new `voice-call-llm-webhook` edge function that proxies to Grok with `stream: true`). `voice-call-start` builds the full system prompt once per call and fetches a short-lived conversation token; the client opens an `ElevenLabs.startConversation(conversationToken:config:)` session (SDK built on LiveKit WebRTC) which owns mic capture, ASR, TTS playback, and barge-in natively. Token billing (`voice-call-checkpoint`/`voice-call-end`) is unchanged, driven by client wall-clock as today.

**Tech Stack:** Swift/SwiftUI (iOS 17+, Xcode 15+/Swift 5.9+), Deno Edge Functions (Supabase), ElevenLabs Conversational AI Swift SDK (`elevenlabs-swift-sdk`, built on LiveKit WebRTC), xAI Grok (`api.x.ai`, OpenAI-compatible).

## Global Constraints

- Supabase project ref: `ohpvhgwjmrfjclnumgnm` (`supabaseURL = https://ohpvhgwjmrfjclnumgnm.supabase.co`).
- ElevenLabs API key is stored as the Supabase secret `ELEVEN_LABS` (already exists, reused from `voice-message-tts`/old `voice-call-turn`) — do not create a differently-named secret for it.
- New Supabase secret required: `ELEVENLABS_AGENT_ID` (set once the Agent is created in Task 6).
- Token pricing unchanged: `TOKENS_PER_SECOND = 3`, `MIN_START_BALANCE = 30`.
- `personality_role` values (exhaustive, used throughout): `crazy`, `devoted`, `flirty`, `playful`, `shy`, `ex`, `distant`. Default fallback where a character's role is unset: `"flirty"`.
- Full spec: `docs/superpowers/specs/2026-07-29-voice-call-agents-migration-design.md`.

---

### Task 1: Verify xAI/Grok streaming support

Resolves the spec's one remaining open question before any webhook code depends on it.

**Files:**
- Create (temporary): `supabase/functions/xai-streaming-verify/index.ts`

- [ ] **Step 1: Write the temporary verification function**

```ts
// supabase/functions/xai-streaming-verify/index.ts
// TEMPORARY — verifies xAI supports `stream: true` before voice-call-llm-webhook
// is built to depend on it. Delete this function once confirmed (Task 1, Step 5).

const XAI_API_KEY = Deno.env.get("XAI_API_KEY") ?? "";

Deno.serve(async () => {
  const resp = await fetch("https://api.x.ai/v1/chat/completions", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${XAI_API_KEY}` },
    body: JSON.stringify({
      model: "grok-4-1-fast-non-reasoning",
      messages: [{ role: "user", content: "Say the word banana three times, nothing else." }],
      stream: true,
      max_tokens: 50,
    }),
  });
  if (!resp.ok || !resp.body) {
    return new Response(`upstream ${resp.status}: ${await resp.text()}`, { status: 502 });
  }
  const reader = resp.body.getReader();
  const decoder = new TextDecoder();
  let raw = "";
  let chunkCount = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    chunkCount++;
    raw += decoder.decode(value, { stream: true });
  }
  return new Response(JSON.stringify({ chunkCount, raw }), {
    headers: { "Content-Type": "application/json" },
  });
});
```

- [ ] **Step 2: Deploy it**

Run: `npx supabase functions deploy xai-streaming-verify`
Expected: `{"message":"Deployed Functions."}`-shaped JSON output.

- [ ] **Step 3: Invoke it and inspect the result**

Run:
```bash
curl -s "https://ohpvhgwjmrfjclnumgnm.supabase.co/functions/v1/xai-streaming-verify" \
  -H "apikey: $(grep supabaseAnonKey -A0 /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/Plumm/Config.swift | sed -E 's/.*\"(sb_[^\"]+)\".*/\1/')" | python3 -m json.tool
```
Expected: `chunkCount` > 1 (proves the response arrived in multiple TCP reads, i.e. actually streamed rather than buffered), and `raw` contains multiple lines starting with `data: ` each holding a `choices[0].delta.content` fragment, ending with a line `data: [DONE]`.

- [ ] **Step 4: Record the outcome**

If confirmed: proceed to Task 4 using `stream: true` exactly as tested — xAI's SSE format is OpenAI-standard, so `voice-call-llm-webhook` can forward it to ElevenLabs almost unchanged (see Task 4).

If NOT confirmed (xAI returns a single non-chunked JSON body even with `stream: true`, or errors): `voice-call-llm-webhook` must instead call xAI non-streaming (`stream: false`, as the old `voice-call-turn` did), get the full `replyText`, then manually re-chunk it into synthetic OpenAI SSE frames (split on whitespace or in fixed-size pieces, one `data: {"choices":[{"delta":{"content":"<piece>"}}]}\n\n` per piece, terminated by `data: [DONE]\n\n`) before returning. This keeps the webhook contract correct for ElevenLabs even without true upstream streaming — Task 4's code below is written to make this swap a same-shaped code change if needed (the SSE-writing logic is isolated from the xAI-calling logic).

- [ ] **Step 5: Delete the verification function**

Run: `npx supabase functions delete xai-streaming-verify`

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: verify xAI streaming support for voice call migration (no code change, temp fn deleted)"
```
(If Step 1's file was deleted before commit, this may be a no-op with nothing to commit — that's fine, skip committing.)

---

### Task 2: Add per-role voice_settings preset

**Files:**
- Create: `supabase/functions/_shared/elevenVoiceSettings.ts`

**Interfaces:**
- Produces: `stabilityFor(role: string): number`, imported by `voice-call-start` (Task 3).

- [ ] **Step 1: Write the preset table**

```ts
// supabase/functions/_shared/elevenVoiceSettings.ts
//
// Static per-personality_role ElevenLabs TTS `stability` preset for voice
// calls (Flash v2.5, via the SDK's TTSOverrides — see
// docs/superpowers/specs/2026-07-29-voice-call-agents-migration-design.md).
// Lower stability = more emotional/prosodic variance between generations;
// higher = flatter, more consistent delivery. There is deliberately no
// `style` knob here — the SDK's TTSOverrides doesn't expose one.

const STABILITY_MAP: Record<string, number> = {
  crazy: 0.25,
  flirty: 0.35,
  playful: 0.35,
  devoted: 0.5,
  ex: 0.5,
  shy: 0.65,
  distant: 0.7,
};

const DEFAULT_STABILITY = 0.4;

export function stabilityFor(role: string): number {
  return STABILITY_MAP[role] ?? DEFAULT_STABILITY;
}
```

- [ ] **Step 2: Commit**

```bash
git add supabase/functions/_shared/elevenVoiceSettings.ts
git commit -m "feat: add per-role TTS stability presets for voice call Agents migration"
```

---

### Task 3: Rewrite `voice-call-start` to build the system prompt once and issue an ElevenLabs conversation token

**Files:**
- Modify: `supabase/functions/voice-call-start/index.ts` (full rewrite)

**Interfaces:**
- Consumes: `fetchDirectiveMemoriesBehaviors(db, characterId, personalityRole, level, conversationId)`, `memoriesBlock(memories)`, `behaviorsBlock(behaviors)`, `REVIEW_DIRECTIVE` from `../_shared/directiveHelpers.ts` (existing, unchanged); `elevenVoiceIdFor(role, vibe)` from `../_shared/elevenVoiceMap.ts` (existing, unchanged); `stabilityFor(role)` from `../_shared/elevenVoiceSettings.ts` (Task 2).
- Produces: response shape `{callSessionId: string, conversationToken: string, systemPrompt: string, voiceId: string, stability: number}` — consumed by `CallService.start()` (Task 9).

- [ ] **Step 1: Replace the file**

```ts
// supabase/functions/voice-call-start/index.ts
//
// Starts a real-time voice call session against an ElevenLabs Agent.
// Finalizes any orphaned `active` session for this user first (crash
// recovery — see voice-call-end for the shared finalize logic), pre-checks
// balance, builds the FULL system prompt ONCE here (memories/behaviors don't
// change mid-call, so unlike the old per-turn voice-call-turn this is never
// re-fetched per turn — see
// docs/superpowers/specs/2026-07-29-voice-call-agents-migration-design.md),
// resolves the character's voice/stability, and fetches a short-lived
// ElevenLabs conversation token so the ElevenLabs API key never reaches the
// client.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  fetchDirectiveMemoriesBehaviors, memoriesBlock, behaviorsBlock, REVIEW_DIRECTIVE,
} from "../_shared/directiveHelpers.ts";
import { elevenVoiceIdFor } from "../_shared/elevenVoiceMap.ts";
import { stabilityFor } from "../_shared/elevenVoiceSettings.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

const ELEVENLABS_API_KEY = Deno.env.get("ELEVEN_LABS") ?? "";
const ELEVENLABS_AGENT_ID = Deno.env.get("ELEVENLABS_AGENT_ID") ?? "";

const TOKENS_PER_SECOND = 3;
const MIN_START_BALANCE = 30; // ~10s of call time

// Replaces the old VOICE_TAGS_RULE — Flash v2.5 doesn't support [bracket]
// audio tags, so emotion has to come through word choice/punctuation instead.
const VOICE_CALL_STYLE_RULE =
  "\n\nSES TARZI KURALI: Bu cevap gerçek zamanlı bir telefon görüşmesinde SESLENDİRİLECEK " +
  "(ElevenLabs Flash modeli, köşeli parantez etiketleri DESTEKLENMİYOR). Duyguyu etiketlerle " +
  "değil kelime seçimi ve noktalamayla ver: heyecanı ünlem işaretiyle, tereddüdü üç nokta (...) " +
  "ile, vurguyu cümle yapısıyla göster. Kısa, doğal cümleler kur — bu bir telefon görüşmesi, " +
  "monolog değil: cevabın 1-2 cümle olsun (nadiren 3), gerçek bir insanın telefonda konuştuğu gibi.";

function userIdFromJWT(authHeader: string | null): string | null {
  if (!authHeader?.startsWith("Bearer ")) return null;
  const token = authHeader.slice(7);
  const parts = token.split(".");
  if (parts.length < 2) return null;
  try {
    let b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    while (b64.length % 4) b64 += "=";
    return JSON.parse(atob(b64)).sub ?? null;
  } catch {
    return null;
  }
}

// Charges for an orphaned/crashed session using its last checkpoint, marks
// it ended. Unchanged from the pre-migration voice-call-start.
async function finalizeOrphaned(uid: string) {
  const { data: orphans } = await db
    .from("call_sessions")
    .select("id, last_checkpoint_seconds")
    .eq("user_id", uid)
    .eq("status", "active");
  if (!orphans || orphans.length === 0) return;
  for (const session of orphans) {
    const tokens = Math.round((session.last_checkpoint_seconds ?? 0) * TOKENS_PER_SECOND);
    if (tokens > 0) {
      await db.rpc("charge_tokens", { p_user_id: uid, p_amount: tokens, p_reason: "voice_call_orphaned" });
    }
    await db.from("call_sessions")
      .update({ status: "ended", ended_at: new Date().toISOString(), tokens_charged: tokens })
      .eq("id", session.id);
  }
}

async function fetchConversationToken(): Promise<{ token: string; conversationId: string }> {
  const url = `https://api.elevenlabs.io/v1/convai/conversation/token?agent_id=${ELEVENLABS_AGENT_ID}`;
  const resp = await fetch(url, { headers: { "xi-api-key": ELEVENLABS_API_KEY } });
  if (!resp.ok) throw new Error(`ElevenLabs token fetch ${resp.status}: ${await resp.text()}`);
  const data = await resp.json();
  return { token: data.token, conversationId: data.conversation_id };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);

    const body = await req.json();
    const characterId: string = body.characterId;
    const conversationId: string | undefined = body.conversationId;
    const reviewMode: boolean = body.reviewMode === true;
    if (!characterId) return json({ error: "characterId required" }, 400);
    if (!ELEVENLABS_AGENT_ID) return json({ error: "ELEVENLABS_AGENT_ID not configured" }, 500);

    await finalizeOrphaned(uid);

    const { data: balanceRow } = await db.from("token_balances").select("balance").eq("user_id", uid).maybeSingle();
    if ((balanceRow?.balance ?? 0) < MIN_START_BALANCE) {
      return json({ error: "insufficient_tokens" }, 402);
    }

    const { data: character } = await db.from("characters")
      .select("personality_role, vibe, voice_id").eq("id", characterId).maybeSingle();
    const personalityRole: string = character?.personality_role ?? "flirty";
    const vibe: string = character?.vibe ?? "Sweet";

    const { directive: fetchedDirective, memories, behaviors } =
      await fetchDirectiveMemoriesBehaviors(db, characterId, personalityRole, 1, conversationId ?? null);
    const directive = reviewMode ? REVIEW_DIRECTIVE : fetchedDirective;
    let systemPrompt = directive;
    systemPrompt += memoriesBlock(memories);
    systemPrompt += behaviorsBlock(behaviors);
    systemPrompt += VOICE_CALL_STYLE_RULE;

    const voiceId = character?.voice_id || elevenVoiceIdFor(personalityRole, vibe);
    const stability = stabilityFor(personalityRole);

    const { data: session, error } = await db.from("call_sessions").insert({
      user_id: uid,
      character_id: characterId,
      conversation_id: conversationId ?? null,
      status: "active",
    }).select("id").single();
    if (error || !session) return json({ error: String(error) }, 500);

    let conversationToken: string;
    try {
      const tokenResult = await fetchConversationToken();
      conversationToken = tokenResult.token;
    } catch (e) {
      // Roll back — no point leaving an active call_sessions row for a call
      // that never actually got an ElevenLabs token to connect with.
      await db.from("call_sessions")
        .update({ status: "ended", ended_at: new Date().toISOString(), tokens_charged: 0 })
        .eq("id", session.id);
      return json({ error: `elevenlabs_token_failed: ${String(e)}` }, 502);
    }

    return json({
      callSessionId: session.id,
      conversationToken,
      systemPrompt,
      voiceId,
      stability,
    });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
```

- [ ] **Step 2: Commit (not deployed yet — deploy happens in Task 6 alongside the webhook and Agent secret)**

```bash
git add supabase/functions/voice-call-start/index.ts
git commit -m "feat: build voice call system prompt once at start, issue ElevenLabs conversation token"
```

---

### Task 4: Create `voice-call-llm-webhook`

**Files:**
- Create: `supabase/functions/voice-call-llm-webhook/index.ts`

**Interfaces:**
- Consumes: HTTP POST from ElevenLabs' infra, body `{messages: {role, content}[], model, temperature, max_tokens, stream, elevenlabs_extra_body?: {callSessionId: string}}` (per Task 1's outcome — this uses the `stream: true` upstream path; if Task 1 found xAI doesn't support streaming, replace the "Step 1" code's SSE-forwarding section per Task 1 Step 4's fallback description, keeping the rest identical).
- Produces: `text/event-stream` response, OpenAI-compatible SSE chunks terminated by `data: [DONE]\n\n`.

- [ ] **Step 1: Write the function**

```ts
// supabase/functions/voice-call-llm-webhook/index.ts
//
// ElevenLabs Agents' custom-LLM webhook target for real-time voice calls.
// Called by ElevenLabs' own infra (not the client) once per conversational
// turn, with the running OpenAI-format message history. The system prompt
// is already correct in that history because voice-call-start set it via
// AgentOverrides.prompt at call start — this function does NO directive/
// memory DB lookup of its own, just streams Grok's reply back as
// OpenAI-compatible SSE and logs the turn for later memory extraction.
//
// Authorization note: ElevenLabs' infra calls this directly, with no
// Supabase user JWT — the callSessionId (arriving via elevenlabs_extra_body,
// set by the client at conversation start) must resolve to a real `active`
// call_sessions row, which is this endpoint's only access control.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const XAI_API_KEY = Deno.env.get("XAI_API_KEY") ?? "";
const XAI_URL = "https://api.x.ai/v1/chat/completions";
const MODEL = "grok-4-1-fast-non-reasoning";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

interface WireMessage { role: string; content: string }

/// Reads an OpenAI-format SSE stream chunk-by-chunk, extracting each
/// delta's text content, and returns the accumulated full reply once the
/// stream ends. Used only for the background call_turns log — never blocks
/// the response already being forwarded to ElevenLabs.
async function accumulateReply(stream: ReadableStream<Uint8Array>): Promise<string> {
  let replyText = "";
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop() ?? "";
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed.startsWith("data: ") || trimmed === "data: [DONE]") continue;
      try {
        const delta = JSON.parse(trimmed.slice(6))?.choices?.[0]?.delta?.content;
        if (delta) replyText += delta;
      } catch {
        // Partial/non-JSON chunk split across two reads — skip, the next
        // read() call completes the line and buffer carries the remainder.
      }
    }
  }
  return replyText.trim();
}

Deno.serve(async (req: Request) => {
  try {
    const body = await req.json();
    const messages: WireMessage[] = body.messages ?? [];
    const callSessionId: string | undefined = body.elevenlabs_extra_body?.callSessionId;

    if (!callSessionId) {
      return new Response(JSON.stringify({ error: "missing callSessionId" }), { status: 400 });
    }
    const { data: session } = await db.from("call_sessions")
      .select("id, status").eq("id", callSessionId).maybeSingle();
    if (!session || session.status !== "active") {
      return new Response(JSON.stringify({ error: "invalid_call_session" }), { status: 400 });
    }

    const lastUserMessage = [...messages].reverse().find((m) => m.role === "user")?.content ?? "";

    const upstream = await fetch(XAI_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${XAI_API_KEY}` },
      body: JSON.stringify({ model: MODEL, messages, temperature: 0.9, max_tokens: 120, stream: true }),
    });
    if (!upstream.ok || !upstream.body) {
      return new Response(JSON.stringify({ error: `xAI ${upstream.status}: ${await upstream.text()}` }), { status: 502 });
    }

    // Tee the upstream SSE stream: one copy forwarded to ElevenLabs untouched
    // (xAI's stream is already OpenAI-format — the exact contract ElevenLabs
    // expects), the other accumulated in the background to log the completed
    // turn once streaming finishes, without delaying the forwarded response.
    const [forwardStream, captureStream] = upstream.body.tee();

    const logPromise = (async () => {
      const replyText = await accumulateReply(captureStream);
      if (replyText) {
        await db.from("call_turns").insert([
          { call_session_id: callSessionId, role: "user", content: lastUserMessage },
          { call_session_id: callSessionId, role: "assistant", content: replyText },
        ]);
      }
    })();
    // deno-lint-ignore no-explicit-any
    (globalThis as any).EdgeRuntime?.waitUntil(logPromise);

    return new Response(forwardStream, {
      headers: { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", Connection: "keep-alive" },
    });
  } catch (e) {
    console.error(String(e));
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});
```

- [ ] **Step 2: Commit (not deployed yet — see Task 6)**

```bash
git add supabase/functions/voice-call-llm-webhook/index.ts
git commit -m "feat: add voice-call-llm-webhook, streams Grok as OpenAI-compatible SSE for ElevenLabs Agents"
```

---

### Task 5: Delete the old `voice-call-turn` function

**Files:**
- Delete: `supabase/functions/voice-call-turn/` (entire directory)

- [ ] **Step 1: Remove the directory**

```bash
rm -rf /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/supabase/functions/voice-call-turn
```

- [ ] **Step 2: Commit**

```bash
git add -A
git commit -m "chore: remove voice-call-turn, replaced by voice-call-llm-webhook"
```

(Remote deletion via `npx supabase functions delete voice-call-turn` happens in Task 6 alongside the other deploys, so the remote function isn't dropped before its replacement is live.)

---

### Task 6: Provision the ElevenLabs Agent, set secrets, deploy

Manual dashboard steps (ElevenLabs has no documented API for one-time Agent creation with all the settings below in this codebase's context — dashboard is the straightforward path for a single, one-time setup):

- [ ] **Step 1: Create the Agent in the ElevenLabs dashboard**

Go to ElevenLabs dashboard → Conversational AI → Create Agent. Configure:
- TTS model: **Flash v2.5**.
- LLM: **Custom LLM**, Server URL: `https://ohpvhgwjmrfjclnumgnm.supabase.co/functions/v1/voice-call-llm-webhook`, Model ID: any placeholder string (e.g. `grok`) — the webhook ignores whatever model ID ElevenLabs sends and always uses its own `grok-4-1-fast-non-reasoning`.
- No static system prompt / first message — both are overridden per-call from the client (`AgentOverrides.prompt`), so leave these at ElevenLabs' defaults.
- Copy the resulting `agent_id` (format `agent_...`).

- [ ] **Step 2: Set the new secret**

```bash
npx supabase secrets set ELEVENLABS_AGENT_ID=<agent_id from Step 1>
```

- [ ] **Step 3: Confirm the existing ElevenLabs API key secret is present**

```bash
npx supabase secrets list | grep ELEVEN_LABS
```
Expected: a row for `ELEVEN_LABS` (already set from prior features — this migration reuses it, no new key needed).

- [ ] **Step 4: Deploy the changed/new functions**

```bash
npx supabase functions deploy voice-call-start
npx supabase functions deploy voice-call-llm-webhook
npx supabase functions delete voice-call-turn
```

- [ ] **Step 5: Verify `voice-call-start` end-to-end with a real request**

Get a real user JWT (e.g. from the app's `UserDefaultsManager.shared.accessToken` during a debug session, or Supabase Studio's auth panel) and a real `characterId` from the `characters` table, then:

```bash
curl -s -X POST "https://ohpvhgwjmrfjclnumgnm.supabase.co/functions/v1/voice-call-start" \
  -H "Authorization: Bearer <user JWT>" \
  -H "apikey: sb_publishable_AdvrSU0EhHDJyWsOtGGhZg_DHca3OaB" \
  -H "Content-Type: application/json" \
  -d '{"characterId": "<real character uuid>", "reviewMode": false}' | python3 -m json.tool
```
Expected: `200` with `callSessionId`, `conversationToken` (long opaque string), `systemPrompt` (non-empty, contains the character's directive text), `voiceId` (an ElevenLabs voice ID string), `stability` (a number 0–1). If `elevenlabs_token_failed` comes back, re-check `ELEVENLABS_AGENT_ID` and the `ELEVEN_LABS` key are both correct.

- [ ] **Step 6: Commit any remaining local changes**

```bash
git status
```
(Nothing to commit if Tasks 3–5 were already committed — this step is just a checkpoint before moving to the client side.)

---

### Task 7: Add the ElevenLabs Swift SDK dependency

**Files:**
- Modify: `Plumm.xcodeproj/project.pbxproj` (via Xcode GUI, not hand-edited — see below)

- [ ] **Step 1: Add the package in Xcode**

Open `Plumm.xcodeproj` in Xcode → File → Add Package Dependencies → enter URL `https://github.com/elevenlabs/elevenlabs-swift-sdk.git` → Dependency Rule: "Up to Next Major Version" starting at `3.2.2` → Add Package → select the `ElevenLabs` product → add to the `Plumm` target.

(Hand-editing `project.pbxproj` to add `XCRemoteSwiftPackageReference`/`XCSwiftPackageProductDependency` entries is avoided here — it's easy to corrupt the project file, and Xcode's own dependency resolution UI is the safe path for this one-time addition.)

- [ ] **Step 2: Verify the package resolves and the project still builds**

```bash
xcodebuild -project /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/Plumm.xcodeproj -scheme Plumm -destination 'generic/platform=iOS Simulator' -sdk iphonesimulator build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```
Expected: `BUILD SUCCEEDED` (package resolves and links even before any file imports it).

- [ ] **Step 3: Confirm microphone permission is already declared**

```bash
grep -r "NSMicrophoneUsageDescription" /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/Plumm/Info.plist 2>/dev/null || grep -r "NSMicrophoneUsageDescription" /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/Plumm.xcodeproj/project.pbxproj
```
Expected: a match (the app already records audio for voice notes via `SpeechRecognizer`/`AVAudioRecorder`, so this should already be declared — the SDK reuses the same permission, no new entry needed). If genuinely missing, add `NSMicrophoneUsageDescription` with a user-facing string to `Info.plist` (or the equivalent `INFOPLIST_KEY_NSMicrophoneUsageDescription` build setting if the project uses generated Info.plist) before proceeding.

- [ ] **Step 4: Commit**

```bash
git add Plumm.xcodeproj/project.pbxproj Plumm.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
git commit -m "chore: add ElevenLabs Conversational AI Swift SDK dependency"
```

---

### Task 8: Drop the dead `voiceCallTurnFunctionURL` from Config

**Files:**
- Modify: `Plumm/Config.swift:72-74`

- [ ] **Step 1: Remove the URL**

Delete these lines (the function they pointed to no longer exists as of Task 5):
```swift
    static var voiceCallTurnFunctionURL: URL {
        URL(string: "\(supabaseURL)/functions/v1/voice-call-turn")!
    }
```

- [ ] **Step 2: Verify no remaining references**

```bash
grep -rn "voiceCallTurnFunctionURL" /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/Plumm
```
Expected: no output (Task 9 removes `CallService.sendTurn()`, the only caller).

- [ ] **Step 3: Commit**

```bash
git add Plumm/Config.swift
git commit -m "chore: remove dead voiceCallTurnFunctionURL"
```

---

### Task 9: Rewrite `CallService.swift`

**Files:**
- Modify: `Plumm/Services/CallService.swift` (full rewrite)

**Interfaces:**
- Produces: `CallService.StartResult { callSessionId: String, conversationToken: String, systemPrompt: String, voiceId: String, stability: Double }`, `CallService.start(characterId:conversationId:reviewMode:) async throws -> StartResult`. `checkpoint()`/`end()` signatures unchanged from before this migration. `sendTurn()` is deleted — consumed by nothing after Task 10.

- [ ] **Step 1: Replace the file**

```swift
//
//  CallService.swift
//  Real-time voice call Edge Functions ile konuşur (voice-call-start/checkpoint/end).
//  Per-turn LLM/TTS is no longer client-driven — voice-call-start now returns
//  everything needed (system prompt, voice, ElevenLabs conversation token) to
//  open an ElevenLabs Agents session directly (bkz. CallViewModel).
//

import Foundation

enum CallServiceError: Error {
    case decoding
    case badStatus(Int, String)
    case insufficientTokens
}

struct CallService {
    private func request(url: URL, body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bearer = UserDefaultsManager.shared.accessToken ?? Config.supabaseAnonKey
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw CallServiceError.decoding }
        return (data, http)
    }

    struct StartResult {
        let callSessionId: String
        let conversationToken: String
        let systemPrompt: String
        let voiceId: String
        let stability: Double
    }

    func start(characterId: String, conversationId: String?, reviewMode: Bool) async throws -> StartResult {
        var body: [String: Any] = ["characterId": characterId, "reviewMode": reviewMode]
        if let conversationId { body["conversationId"] = conversationId }
        let (data, http) = try await request(url: Config.voiceCallStartFunctionURL, body: body)
        if http.statusCode == 402 { throw CallServiceError.insufficientTokens }
        guard http.statusCode == 200 else {
            throw CallServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct Response: Decodable {
            let callSessionId: String
            let conversationToken: String
            let systemPrompt: String
            let voiceId: String
            let stability: Double
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw CallServiceError.decoding }
        return StartResult(
            callSessionId: decoded.callSessionId,
            conversationToken: decoded.conversationToken,
            systemPrompt: decoded.systemPrompt,
            voiceId: decoded.voiceId,
            stability: decoded.stability
        )
    }

    func checkpoint(callSessionId: String, elapsedSeconds: Double) async throws -> Bool {
        let body: [String: Any] = ["callSessionId": callSessionId, "elapsedSeconds": elapsedSeconds]
        let (data, http) = try await request(url: Config.voiceCallCheckpointFunctionURL, body: body)
        guard http.statusCode == 200 else {
            throw CallServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct Response: Decodable { let ok: Bool }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw CallServiceError.decoding }
        return decoded.ok
    }

    @discardableResult
    func end(callSessionId: String, actualElapsedSeconds: Double) async throws -> (tokensCharged: Int, newBalance: Int) {
        let body: [String: Any] = ["callSessionId": callSessionId, "actualElapsedSeconds": actualElapsedSeconds]
        let (data, http) = try await request(url: Config.voiceCallEndFunctionURL, body: body)
        guard http.statusCode == 200 else {
            throw CallServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct Response: Decodable { let tokensCharged: Int; let newBalance: Int }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw CallServiceError.decoding }
        return (decoded.tokensCharged, decoded.newBalance)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Plumm/Services/CallService.swift
git commit -m "feat: CallService.start returns ElevenLabs conversation token + prebuilt system prompt"
```

---

### Task 10: Rewrite `CallViewModel.swift` around the ElevenLabs SDK

**Files:**
- Modify: `Plumm/ViewModels/CallViewModel.swift` (full rewrite)

**Interfaces:**
- Consumes: `CallService.StartResult` (Task 9); `ElevenLabs.startConversation(conversationToken:config:) async throws -> Conversation`, `ConversationConfig(agentOverrides:ttsOverrides:customLlmExtraBody:onDisconnect:onError:onUserTranscript:onAgentResponse:onAgentStateChange:)`, `AgentOverrides(prompt:)`, `TTSOverrides(voiceId:stability:)`, `Conversation.endConversation() async`, `Conversation.sendMessage(_:) async throws`, `Conversation.setMuted(_:) async throws`, `ElevenLabs.AgentState` (`.listening`/`.speaking`/`.thinking`), `DisconnectionReason` (`.agent`/`.user`/`.error`) — all from the `ElevenLabs` SDK package (Task 7).
- Produces: `CallState` enum **unchanged in shape** from before this migration (`.idle`/`.listening`/`.thinking`/`.speaking`/`.ended(reason:)` with the same `EndReason` cases) — `VoiceCallView` (Task 11) needs no changes as a result. `elapsedSeconds: Double`, `debugLog: [String]`, `sendTypedText(_:) async`, `toggleMute()`, `startCall() async`, `endCall() async` all keep their existing names/signatures from `VoiceCallView`'s perspective.

- [ ] **Step 1: Replace the file**

```swift
//
//  CallViewModel.swift
//  Real-time voice call durumu, backed by an ElevenLabs Agents session
//  (Flash v2.5). The SDK (built on LiveKit WebRTC) owns mic capture, ASR,
//  TTS playback, and barge-in natively — this class just wires our token
//  billing and DEBUG logging around it. See
//  docs/superpowers/specs/2026-07-29-voice-call-agents-migration-design.md.
//

import Foundation
import ElevenLabs
import Observation

enum CallState: Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case ended(reason: EndReason)

    enum EndReason: Equatable { case userEnded, insufficientTokens, error }
}

@MainActor
@Observable
final class CallViewModel {
    let character: Character
    let conversationId: String?
    var tokenStore: TokenStore?

    var state: CallState = .idle
    var isMuted: Bool = false
    var errorMessage: String?

    // TEMP DEBUG — remove once voice call pipeline is verified on device.
    var debugLog: [String] = []
    private func debug(_ s: String) { debugLog.append(s) }

    private let service = CallService()
    private var conversation: Conversation?

    private var callSessionId: String?
    private var callStartedAt: Date?
    private var checkpointTask: Task<Void, Never>?

    init(character: Character, conversationId: String?) {
        self.character = character
        self.conversationId = conversationId
    }

    var elapsedSeconds: Double {
        guard let callStartedAt else { return 0 }
        return Date().timeIntervalSince(callStartedAt)
    }

    private var isEnded: Bool {
        if case .ended = state { return true }
        return false
    }

    func startCall() async {
        debug("Calling voice-call-start…")
        let result: CallService.StartResult
        do {
            result = try await service.start(
                characterId: character.id.uuidString.lowercased(),
                conversationId: conversationId,
                reviewMode: ReviewModeService.isEnabledSnapshot
            )
            debug("Call started, session \(result.callSessionId)")
        } catch CallServiceError.insufficientTokens {
            debug("voice-call-start: insufficient tokens")
            state = .ended(reason: .insufficientTokens)
            return
        } catch {
            debug("voice-call-start failed: \(error)")
            errorMessage = String(localized: "Couldn't start the call.")
            state = .ended(reason: .error)
            return
        }
        callSessionId = result.callSessionId

        let config = ConversationConfig(
            agentOverrides: AgentOverrides(prompt: result.systemPrompt),
            ttsOverrides: TTSOverrides(voiceId: result.voiceId, stability: result.stability),
            customLlmExtraBody: ["callSessionId": result.callSessionId],
            onDisconnect: { [weak self] reason in
                Task { @MainActor in self?.handleDisconnect(reason) }
            },
            onError: { [weak self] error in
                Task { @MainActor in self?.debug("SDK error: \(error)") }
            },
            onUserTranscript: { [weak self] text, _ in
                Task { @MainActor in self?.debug("User said: \"\(text)\"") }
            },
            onAgentResponse: { [weak self] text, _ in
                Task { @MainActor in self?.debug("Agent said: \"\(text)\"") }
            },
            onAgentStateChange: { [weak self] agentState in
                Task { @MainActor in self?.applyAgentState(agentState) }
            }
        )

        do {
            debug("Connecting to ElevenLabs Agent…")
            conversation = try await ElevenLabs.startConversation(
                conversationToken: result.conversationToken, config: config
            )
            debug("Agent connected")
        } catch {
            debug("ElevenLabs connect failed: \(error)")
            errorMessage = String(localized: "Couldn't connect the call.")
            state = .ended(reason: .error)
            return
        }

        callStartedAt = Date()
        state = .listening
        startCheckpointLoop()
    }

    private func applyAgentState(_ agentState: ElevenLabs.AgentState) {
        guard !isEnded else { return }
        switch agentState {
        case .listening: state = .listening
        case .thinking: state = .thinking
        case .speaking: state = .speaking
        }
    }

    private func handleDisconnect(_ reason: DisconnectionReason) {
        guard !isEnded else { return }
        debug("Disconnected: \(reason)")
        if reason == .error {
            errorMessage = String(localized: "The call was disconnected.")
            state = .ended(reason: .error)
        } else {
            state = .ended(reason: .userEnded)
        }
    }

    func endCall() async {
        checkpointTask?.cancel()
        await conversation?.endConversation()
        conversation = nil

        let finalElapsed = elapsedSeconds
        debug("Ending call, elapsedSeconds=\(finalElapsed)")
        if let callSessionId {
            do {
                let result = try await service.end(callSessionId: callSessionId, actualElapsedSeconds: finalElapsed)
                debug("voice-call-end: charged \(result.tokensCharged) tokens, newBalance=\(result.newBalance)")
                tokenStore?.setBalance(result.newBalance)
            } catch {
                debug("voice-call-end FAILED: \(error)")
            }
        } else {
            debug("Ending call: no callSessionId — never started, nothing to charge")
        }
        if !isEnded { state = .ended(reason: .userEnded) }
    }

    func toggleMute() {
        isMuted.toggle()
        Task { try? await conversation?.setMuted(isMuted) }
    }

    /// Text fallback for a turn — same pipeline as a spoken turn (the Agent
    /// treats it identically to a transcribed utterance).
    func sendTypedText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let conversation else { return }
        debug("Typed: \"\(trimmed)\"")
        do {
            try await conversation.sendMessage(trimmed)
        } catch {
            debug("sendMessage failed: \(error)")
            errorMessage = String(localized: "That message failed — try again.")
        }
    }

    // MARK: - Checkpointing

    private func startCheckpointLoop() {
        checkpointTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let callSessionId else { continue }
                let ok = (try? await service.checkpoint(callSessionId: callSessionId, elapsedSeconds: elapsedSeconds)) ?? true
                if !ok {
                    state = .ended(reason: .insufficientTokens)
                    await endCall()
                    return
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/Plumm.xcodeproj -scheme Plumm -destination 'generic/platform=iOS Simulator' -sdk iphonesimulator build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```
Expected: `BUILD SUCCEEDED`. If the SDK's actual shipped API differs from what's documented here (SDKs move fast — re-verify against `gh api repos/elevenlabs/elevenlabs-swift-sdk/contents/Sources/ElevenLabs/Public/Conversation/ConversationConfig.swift` if so), fix the mismatch inline — the design intent (agent-prompt override, tts voiceId/stability override, extra_body carrying callSessionId, agentState-driven CallState, sendMessage for text fallback) is what must be preserved, not the exact code above verbatim.

- [ ] **Step 3: Commit**

```bash
git add Plumm/ViewModels/CallViewModel.swift
git commit -m "feat: rewrite CallViewModel around ElevenLabs Agents SDK, delete REST turn-loop"
```

---

### Task 11: Verify `VoiceCallView.swift` needs no changes, then manual end-to-end test

`CallState`'s shape is unchanged (Task 10), so `VoiceCallView`'s `statusLabel` switch, `elapsedLabel`, DEBUG overlay `ForEach(viewModel.debugLog...)`, and the typed-text field (still calling `viewModel.sendTypedText(_:)`) all continue to compile and behave correctly without modification.

**Files:**
- None modified — verification only.

- [ ] **Step 1: Confirm no leftover references to deleted APIs**

```bash
grep -rn "SpeechRecognizer\|recognizer\." /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/Plumm/Views/VoiceCallView.swift /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/Plumm/ViewModels/CallViewModel.swift
```
Expected: no output (calls no longer touch `SpeechRecognizer` at all — it's still used elsewhere by `ChatView`, untouched).

- [ ] **Step 2: Full project build**

```bash
xcodebuild -project /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/Plumm.xcodeproj -scheme Plumm -destination 'generic/platform=iOS Simulator' -sdk iphonesimulator build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Manual end-to-end test on a real device**

(Simulator mic/audio HAL is known-flaky per prior debugging in this project — real device is the reliable test path here, same caveat as the old pipeline.)

Run through this checklist on a real device build:
1. Open a character's chat, tap the call icon. Screen shows "Connecting…", DEBUG overlay logs `Calling voice-call-start…`, `Call started, session <uuid>`, `Connecting to ElevenLabs Agent…`, `Agent connected`.
2. Status moves to "Listening…", elapsed timer starts counting from `00:00`.
3. Speak a short question. DEBUG overlay logs `User said: "..."` and shortly after `Agent said: "..."` — the gap between these two log lines should be visibly under 2-3 seconds (vs. ~15s on the old pipeline).
4. While the agent is speaking, talk over it — confirm it stops and starts listening again (native barge-in via `onInterruption`/state transition, no custom polling code involved anymore).
5. Type a message into the text field and send it mid-call — confirm the agent responds to it the same as a spoken turn.
6. Tap the mute button, confirm `isMuted` toggles and the agent stops registering your speech.
7. End the call. DEBUG overlay logs `Ending call, elapsedSeconds=<N>`, then `voice-call-end: charged <N*3> tokens, newBalance=<X>` — confirm the app's token balance display actually dropped by that amount.
8. In Supabase Studio, check the `call_turns` table for this `call_session_id` — confirm both `user` and `assistant` rows exist with real transcript content (proves the webhook's fire-and-forget logging worked).
9. Confirm a few minutes later (or by checking the character's `memories` table) that memory extraction ran on hangup — same as the pre-migration behavior, since `voice-call-end` itself didn't change.

- [ ] **Step 4: Commit the DEBUG-overlay-still-present state as final for this migration**

No file changes expected from this task, so nothing to commit unless Step 3 surfaced a bug fixed inline — in that case, commit that fix with a message describing what broke and why.
