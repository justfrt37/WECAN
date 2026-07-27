# Real-Time Voice Call Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the real-time barge-in voice call feature per `docs/superpowers/specs/2026-07-28-voice-call-design.md` — Grok text replies spoken via ElevenLabs, full duplex (listen while AI talks), time-based billing settled at call end, separate `call_sessions`/`call_turns` log (never touches the normal chat thread).

**Architecture:** Four new Supabase edge functions (`voice-call-start/turn/checkpoint/end`) share directive/memory-fetch logic with `chat/index.ts` via a new `_shared/directiveHelpers.ts` module. Client gets a `CallService` (network) + `CallViewModel` (state machine: `listening → thinking → speaking`, with barge-in during `speaking`) + `VoiceCallView` (full-screen voice-only UI), reachable from a new phone-icon button in `ChatView`'s header.

**Tech Stack:** Deno edge functions (TypeScript) + Supabase Postgres/Storage. SwiftUI/Swift client — `AVAudioSession(.playAndRecord, .voiceChat)` for full-duplex echo-cancelled audio, `SFSpeechRecognizer` for on-device STT. No local Deno CLI, no Xcode test target (same constraint as every prior plan in this repo) — backend verification is diff review + `npx supabase functions deploy` + `functions list`; client verification is `xcodebuild build` + manual call testing (this device has a working mic/speaker; the emulator does not need to place a real call to verify compilation).

## Global Constraints

- Billing: 3 tokens/sec of call wall-clock time, charged **once** at call end via the existing `charge_tokens` RPC — never per-turn.
- Checkpoints every 5s are a recovery marker only (`call_sessions.last_checkpoint_seconds`) — they never call `charge_tokens`.
- Any romantic/flirty content in the call directive must stay gated behind `!reviewMode` (App Store compliance — `REVIEW_DIRECTIVE` swap), same rule `chat/index.ts` already follows.
- Call turns never write to the `messages` table and never appear in the normal chat thread — they live only in `call_sessions`/`call_turns`.
- No sentence-streaming TTS, no live captions UI — full-reply-first, voice-only screen (both explicitly deferred by the spec).

---

### Task 1: Extract shared directive/memory helpers to `_shared/directiveHelpers.ts`

`voice-call-turn` (Task 5) needs the exact same character-directive + memories + behaviors fetch that `chat/index.ts` already has. Extracting it first means Task 5 imports proven code instead of duplicating ~60 lines.

**Files:**
- Create: `supabase/functions/_shared/directiveHelpers.ts`
- Modify: `supabase/functions/chat/index.ts:153-243` (the `directiveCache`/`fetchDirective`/`fetchDirectiveMemoriesBehaviors`/`memoriesBlock`/`behaviorsBlock`/`REVIEW_DIRECTIVE` block)

**Interfaces:**
- Produces: `fetchDirective(db, characterId, role, level): Promise<string>`, `fetchDirectiveMemoriesBehaviors(db, characterId, role, level, conversationId): Promise<{directive, memories, behaviors}>`, `memoriesBlock(memories): string`, `behaviorsBlock(behaviors): string`, `REVIEW_DIRECTIVE: string` — all consumed by Task 5.

- [ ] **Step 1: Create the shared module**

Create `supabase/functions/_shared/directiveHelpers.ts`:

```typescript
// supabase/functions/_shared/directiveHelpers.ts
//
// Character directive + memories + behaviors fetch, shared between chat/index.ts
// and voice-call-turn/index.ts — both need the exact same "what does this
// character know and how should it currently behave" assembly.

// Deno-agnostic minimal client type — callers pass their own `db` (createClient
// result) so this module never creates its own connection/env dependency.
type DB = ReturnType<typeof import("https://esm.sh/@supabase/supabase-js@2").createClient>;

const directiveCache = new Map<string, { directive: string; expiresAt: number }>();
const DIRECTIVE_TTL_MS = 5 * 60_000;

export async function fetchDirective(db: DB, characterId: string, role: string, level: number): Promise<string> {
  const key = `${characterId}:${role}:${level}`;
  const now = Date.now();
  const cached = directiveCache.get(key);
  if (cached && cached.expiresAt > now) return cached.directive;

  const { data: override } = await db
    .from("character_level_overrides")
    .select("directive")
    .eq("character_id", characterId)
    .eq("level", level)
    .maybeSingle();

  let directive: string;
  if (override?.directive) {
    directive = override.directive;
  } else {
    const { data: script } = await db
      .from("role_level_scripts")
      .select("directive")
      .eq("role", role)
      .eq("level", level)
      .maybeSingle();
    directive = script?.directive ?? `İlişki seviyesi ${level}/10. Doğal ve sıcak ol.`;
  }

  directiveCache.set(key, { directive, expiresAt: now + DIRECTIVE_TTL_MS });
  return directive;
}

export async function fetchDirectiveMemoriesBehaviors(
  db: DB,
  characterId: string,
  role: string,
  level: number,
  conversationId: string,
): Promise<{
  directive: string;
  memories: { content: string }[];
  behaviors: { content: string }[];
}> {
  const [directive, memoriesResult, behaviorsResult] = await Promise.all([
    fetchDirective(db, characterId, role, level),
    db.from("memories").select("content").eq("conversation_id", conversationId)
      .order("created_at", { ascending: true }),
    db.from("conversation_behaviors").select("content").eq("conversation_id", conversationId)
      .order("created_at", { ascending: true }),
  ]);
  return {
    directive,
    memories: (memoriesResult.data ?? []) as { content: string }[],
    behaviors: (behaviorsResult.data ?? []) as { content: string }[],
  };
}

export function memoriesBlock(memories: { content: string }[]): string {
  if (memories.length === 0) return "";
  return `\n\n[MEMORIES — facts to remember about the user/relationship]\n` +
    memories.map((m) => `- ${m.content}`).join("\n");
}

export function behaviorsBlock(behaviors: { content: string }[]): string {
  if (behaviors.length === 0) return "";
  return `\n\n[BEHAVIOR PREFERENCES — how the user wants you to act]\n` +
    behaviors.map((b) => `- ${b.content}`).join("\n");
}

// Review Mode (App Store inceleme) direktifi — flört/romantizm İÇERMEZ. Rol
// bazlı direktifin yerine geçer (bkz. ReviewModeService.swift).
export const REVIEW_DIRECTIVE =
  "You are a warm, friendly companion and nothing more. Keep the entire " +
  "conversation strictly platonic, wholesome and respectful. Do NOT flirt, do " +
  "NOT give romantic compliments, do NOT be seductive, suggestive or sexual in " +
  "any way, and never steer the conversation toward romance or dating. Chat like " +
  "a kind, supportive friend about everyday topics (hobbies, feelings, daily life).";
```

- [ ] **Step 2: Point `chat/index.ts` at the shared module**

In `supabase/functions/chat/index.ts`, find the import block near the top:

```typescript
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { franc } from "https://esm.sh/franc-min@6";
```

Replace with:

```typescript
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { franc } from "https://esm.sh/franc-min@6";
import {
  fetchDirective as sharedFetchDirective,
  fetchDirectiveMemoriesBehaviors as sharedFetchDirectiveMemoriesBehaviors,
  memoriesBlock,
  behaviorsBlock,
  REVIEW_DIRECTIVE,
} from "../_shared/directiveHelpers.ts";
```

Now find the block being replaced (lines 153-243, from the `directiveCache` comment through the end of `REVIEW_DIRECTIVE`):

```typescript
// In-memory cache for fetchDirective — directives only change on level-up
// or a developer hand-editing character_level_overrides/role_level_scripts
// (active during current tuning work), hence a 5-minute TTL rather than
// caching forever per warm instance. Module-level so it survives across
// invocations on the same warm edge-function instance.
const directiveCache = new Map<string, { directive: string; expiresAt: number }>();
const DIRECTIVE_TTL_MS = 5 * 60_000;

// Fetch role-aware intimacy directive from DB.
// Checks character_level_overrides first, falls back to role_level_scripts.
async function fetchDirective(characterId: string, role: string, level: number): Promise<string> {
```

...through to (inclusive):

```typescript
// Review Mode (App Store inceleme) direktifi — flört/romantizm İÇERMEZ. Rol
// bazlı direktifin (fetchDirective) yerine geçer; bkz. ReviewModeService.swift.
const REVIEW_DIRECTIVE =
  "You are a warm, friendly companion and nothing more. Keep the entire " +
  "conversation strictly platonic, wholesome and respectful. Do NOT flirt, do " +
  "NOT give romantic compliments, do NOT be seductive, suggestive or sexual in " +
  "any way, and never steer the conversation toward romance or dating. Chat like " +
  "a kind, supportive friend about everyday topics (hobbies, feelings, daily life).";
```

Delete that entire block, and add two thin wrapper functions in its place (keeping every existing call site in `chat/index.ts` working unchanged, since they call `fetchDirective(characterId, ...)`/`fetchDirectiveMemoriesBehaviors(characterId, ...)` without a `db` argument):

```typescript
async function fetchDirective(characterId: string, role: string, level: number): Promise<string> {
  return sharedFetchDirective(db, characterId, role, level);
}

async function fetchDirectiveMemoriesBehaviors(
  characterId: string, role: string, level: number, conversationId: string,
) {
  return sharedFetchDirectiveMemoriesBehaviors(db, characterId, role, level, conversationId);
}
```

- [ ] **Step 3: Verify nothing else in `chat/index.ts` broke**

Run: `grep -n "memoriesBlock\|behaviorsBlock\|REVIEW_DIRECTIVE\|fetchDirective(\|fetchDirectiveMemoriesBehaviors(" supabase/functions/chat/index.ts`
Expected: `memoriesBlock`/`behaviorsBlock`/`REVIEW_DIRECTIVE` call sites unchanged (now resolving to the imports), `fetchDirective`/`fetchDirectiveMemoriesBehaviors` call sites unchanged (now resolving to the two thin wrappers). No duplicate `const REVIEW_DIRECTIVE` or duplicate `function memoriesBlock` left in the file.

Run: `git diff supabase/functions/chat/index.ts`
Expected: import block gained 6 lines; the old ~90-line helper block replaced by two ~5-line wrapper functions; nothing else in the file touched.

- [ ] **Step 4: Commit**

```bash
git add supabase/functions/_shared/directiveHelpers.ts supabase/functions/chat/index.ts
git commit -m "refactor(chat): extract directive/memory helpers to _shared for voice-call reuse"
```

---

### Task 2: Move `elevenVoiceIdFor` to `_shared/elevenVoiceMap.ts`

`voice-call-turn` needs the same role×vibe → ElevenLabs voice_id map `voice-message-tts` already has.

**Files:**
- Create: `supabase/functions/_shared/elevenVoiceMap.ts` (moved from `supabase/functions/voice-message-tts/elevenVoiceMap.ts`)
- Delete: `supabase/functions/voice-message-tts/elevenVoiceMap.ts`
- Modify: `supabase/functions/voice-message-tts/index.ts:14`

**Interfaces:**
- Produces: `elevenVoiceIdFor(role: string, vibe: string): string` — consumed by Task 5.

- [ ] **Step 1: Move the file**

```bash
git mv supabase/functions/voice-message-tts/elevenVoiceMap.ts supabase/functions/_shared/elevenVoiceMap.ts
```

- [ ] **Step 2: Fix the import in `voice-message-tts/index.ts`**

Find:
```typescript
import { elevenVoiceIdFor } from "./elevenVoiceMap.ts";
```
Replace:
```typescript
import { elevenVoiceIdFor } from "../_shared/elevenVoiceMap.ts";
```

- [ ] **Step 3: Verify**

Run: `git status --short supabase/functions/`
Expected: `elevenVoiceMap.ts` shows as renamed (`R`) from `voice-message-tts/` to `_shared/`; `voice-message-tts/index.ts` shows modified.

Run: `grep -n "elevenVoiceIdFor" supabase/functions/voice-message-tts/index.ts`
Expected: import line points at `../_shared/elevenVoiceMap.ts`, usage site (`elevenVoiceIdFor(role, vibe)`) unchanged.

- [ ] **Step 4: Commit**

```bash
git add -A supabase/functions/_shared/elevenVoiceMap.ts supabase/functions/voice-message-tts/
git commit -m "refactor(voice): move elevenVoiceMap to _shared for voice-call reuse"
```

---

### Task 3: Database migration — `call_sessions` + `call_turns`

**Files:**
- Create: `supabase/migrations/017_voice_calls.sql`

**Interfaces:**
- Produces: tables `call_sessions(id, user_id, character_id, conversation_id, status, started_at, ended_at, last_checkpoint_seconds, tokens_charged)` and `call_turns(id, call_session_id, role, content, audio_url, created_at)` — consumed by Tasks 4/5/6/7.

- [ ] **Step 1: Write the migration**

Create `supabase/migrations/017_voice_calls.sql`:

```sql
-- 017_voice_calls.sql
-- Real-time voice call feature — separate log from the normal `messages`
-- table (bkz. docs/superpowers/specs/2026-07-28-voice-call-design.md).
-- Client never queries these directly (no PostgREST access needed) — only
-- the voice-call-* edge functions (service_role) touch them, so RLS is
-- enabled with no policy, same pattern as conversation_behaviors/shot_templates
-- (bkz. migration 012_enable_rls.sql).

create table if not exists call_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  character_id uuid not null references characters(id) on delete cascade,
  conversation_id uuid references conversations(id) on delete cascade,
  status text not null default 'active', -- 'active' | 'ended'
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  last_checkpoint_seconds int not null default 0,
  tokens_charged int
);

create table if not exists call_turns (
  id uuid primary key default gen_random_uuid(),
  call_session_id uuid not null references call_sessions(id) on delete cascade,
  role text not null, -- 'user' | 'assistant'
  content text not null,
  audio_url text,
  created_at timestamptz not null default now()
);

create index if not exists call_sessions_user_status_idx on call_sessions(user_id, status);
create index if not exists call_turns_session_idx on call_turns(call_session_id, created_at);

alter table call_sessions enable row level security;
alter table call_turns enable row level security;
```

- [ ] **Step 2: Apply the migration**

Run: `npx supabase db push --project-ref ohpvhgwjmrfjclnumgnm` (see `[[supabase_access]]` memory for auth if it prompts for login).
Expected: output confirms `017_voice_calls.sql` applied, no errors.

- [ ] **Step 3: Verify the tables exist**

Run: `npx supabase db diff --project-ref ohpvhgwjmrfjclnumgnm --schema public 2>&1 | head -5`
Expected: no pending diff for `call_sessions`/`call_turns` (they now match migration state — command may report "No schema changes found" or similar).

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/017_voice_calls.sql
git commit -m "feat(db): add call_sessions/call_turns tables for voice call feature"
```

---

### Task 4: `voice-call-start` edge function

**Files:**
- Create: `supabase/functions/voice-call-start/index.ts`

**Interfaces:**
- Consumes: `call_sessions` table (Task 3).
- Produces: `POST /voice-call-start` — input `{characterId: string, conversationId: string}`, output `{callSessionId: string}` (200) or `{error: "insufficient_tokens"}` (402) or `{error: "unauthorized"}` (401) — consumed by Task 9 (`CallService`).

- [ ] **Step 1: Write the function**

Create `supabase/functions/voice-call-start/index.ts`:

```typescript
// supabase/functions/voice-call-start/index.ts
//
// Starts a real-time voice call session. Finalizes any orphaned `active`
// session for this user first (crash recovery — see voice-call-end for the
// shared finalize logic), pre-checks balance, creates the new session row.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

const TOKENS_PER_SECOND = 3;
const MIN_START_BALANCE = 30; // ~10s of call time

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
// it ended. Shared shape with voice-call-end's real finalize path, but kept
// as its own small copy here — voice-call-end additionally runs memory
// extraction, which an orphaned-session finalize should NOT do (no graceful
// end, no guarantee the transcript is coherent to summarize).
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
    if (!characterId) return json({ error: "characterId required" }, 400);

    await finalizeOrphaned(uid);

    const { data: balanceRow } = await db.from("token_balances").select("balance").eq("user_id", uid).maybeSingle();
    if ((balanceRow?.balance ?? 0) < MIN_START_BALANCE) {
      return json({ error: "insufficient_tokens" }, 402);
    }

    const { data: session, error } = await db.from("call_sessions").insert({
      user_id: uid,
      character_id: characterId,
      conversation_id: conversationId ?? null,
      status: "active",
    }).select("id").single();

    if (error || !session) return json({ error: String(error) }, 500);
    return json({ callSessionId: session.id });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
```

- [ ] **Step 2: Deploy and smoke-test**

Run: `npx supabase functions deploy voice-call-start --project-ref ohpvhgwjmrfjclnumgnm`
Expected: `"message":"Deployed Functions."`.

Run: `npx supabase functions list --project-ref ohpvhgwjmrfjclnumgnm | grep voice-call-start`
Expected: shows the function with a recent updated timestamp.

- [ ] **Step 3: Commit**

```bash
git add supabase/functions/voice-call-start/index.ts
git commit -m "feat(backend): add voice-call-start edge function"
```

---

### Task 5: `voice-call-turn` edge function

**Files:**
- Create: `supabase/functions/voice-call-turn/index.ts`

**Interfaces:**
- Consumes: `fetchDirectiveMemoriesBehaviors`, `memoriesBlock`, `behaviorsBlock`, `REVIEW_DIRECTIVE` (Task 1); `elevenVoiceIdFor` (Task 2); `call_sessions`/`call_turns` (Task 3).
- Produces: `POST /voice-call-turn` — input `{callSessionId: string, userTranscript: string, reviewMode?: boolean}`, output `{replyText: string, audioBase64: string}` (200) — consumed by Task 9.

- [ ] **Step 1: Write the function**

Create `supabase/functions/voice-call-turn/index.ts`:

```typescript
// supabase/functions/voice-call-turn/index.ts
//
// One turn of a real-time voice call: user transcript in, Grok text reply +
// ElevenLabs audio out. Writes both turns to call_turns (NOT messages — a
// call is logged separately from the normal chat thread, bkz. design spec).
// No per-turn token charge — billing is time-based, settled once in
// voice-call-end.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  fetchDirectiveMemoriesBehaviors, memoriesBlock, behaviorsBlock, REVIEW_DIRECTIVE,
} from "../_shared/directiveHelpers.ts";
import { elevenVoiceIdFor } from "../_shared/elevenVoiceMap.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const XAI_API_KEY = Deno.env.get("XAI_API_KEY") ?? "";
const XAI_URL = "https://api.x.ai/v1/chat/completions";
const MODEL = "grok-4-1-fast-non-reasoning";

const ELEVENLABS_API_KEY = Deno.env.get("ELEVEN_LABS") ?? "";
const ELEVENLABS_TTS_URL = "https://api.elevenlabs.io/v1/text-to-speech";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

// Same [tag] rule chat/index.ts uses for ElevenLabs v3 voice replies — kept
// as its own copy (not moved to _shared) since chat/index.ts's version also
// interacts with that file's PAUSE-tag/segment machinery, which calls never use.
const VOICE_TAGS_RULE =
  "\n\nSES ETİKETİ KURALI: Bu cevap sesli olarak seslendirilecek (ElevenLabs v3 " +
  "modeli). Bu etiketler seslendirmeyi İNANILMAZ derecede gerçekçi yapıyor — bu " +
  "yüzden onları YOĞUN ve CÖMERT biçimde kullan, nadiren değil. Neredeyse HER " +
  "cümlenin başına (bazen cümle ortasında bir vurgu için de) uygun bir etiket " +
  "koy — amaç minimum değil, mümkün olduğunca doğal ve duygu dolu bir seslendirme. " +
  "Kullanabileceğin etiketler (İngilizce, köşeli parantez içinde, tam bu şekilde " +
  "yaz): [laughs], [sighs], [whispers], [gasps], [excited], [nervous], [curious], " +
  "[playfully], [flatly], [sarcastic tone], [pauses], [hesitates], [cheerfully], " +
  "[wistful], [giggles], [teasing], [breathless], [softly], [moans]. Karakterine " +
  "ve o anki duygu durumuna uygun etiketleri seç, ama az kullanmaktan ÇEKİNME — " +
  "her cümlede en az bir etiket olsun. Etiketler dışındaki metin yine konuştuğun " +
  "dilde kalsın; sadece etiketlerin kendisi İngilizce ve köşeli parantez " +
  "biçiminde olmalı. Bu bir SESLİ ARAMA — cevabın DOĞAL, sürekli konuşma akışı " +
  "olsun, [PAUSE:n] gibi hiçbir zamanlama etiketi KULLANMA.";

interface WireMessage { role: string; content: string }

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

async function callGrok(messages: WireMessage[], maxTokens: number, convId?: string): Promise<string> {
  const resp = await fetch(XAI_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${XAI_API_KEY}`,
      ...(convId ? { "x-grok-conv-id": convId } : {}),
    },
    body: JSON.stringify({ model: MODEL, messages, temperature: 0.9, max_tokens: maxTokens }),
  });
  if (!resp.ok) throw new Error(`LLM ${resp.status}: ${await resp.text()}`);
  const data = await resp.json();
  return data?.choices?.[0]?.message?.content ?? "";
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

async function uploadCallAudio(bytes: Uint8Array, callSessionId: string): Promise<string | null> {
  const path = `voices/calls/${callSessionId}/${crypto.randomUUID()}.mp3`;
  const { error } = await db.storage.from("characters").upload(path, bytes, {
    contentType: "audio/mpeg", upsert: false,
  });
  if (error) return null;
  const { data } = db.storage.from("characters").getPublicUrl(path);
  return data.publicUrl;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);

    const body = await req.json();
    const callSessionId: string = body.callSessionId;
    const userTranscript: string = (body.userTranscript ?? "").trim();
    const reviewMode: boolean = body.reviewMode === true;
    if (!callSessionId || !userTranscript) return json({ error: "callSessionId and userTranscript required" }, 400);

    const { data: session, error: sessionErr } = await db
      .from("call_sessions")
      .select("id, user_id, character_id, conversation_id, status")
      .eq("id", callSessionId)
      .maybeSingle();
    if (sessionErr || !session || session.user_id !== uid || session.status !== "active") {
      return json({ error: "invalid_call_session" }, 400);
    }

    const [{ data: character }, { data: turnHistory }] = await Promise.all([
      db.from("characters").select("personality_role, vibe, voice_id").eq("id", session.character_id).maybeSingle(),
      db.from("call_turns").select("role, content").eq("call_session_id", callSessionId)
        .order("created_at", { ascending: true }),
    ]);

    const personalityRole: string = character?.personality_role ?? "flirty";
    const vibe: string = character?.vibe ?? "Sweet";
    const conversationId: string = session.conversation_id;

    const { directive: fetchedDirective, memories, behaviors } =
      await fetchDirectiveMemoriesBehaviors(db, session.character_id, personalityRole, 1, conversationId);
    const directive = reviewMode ? REVIEW_DIRECTIVE : fetchedDirective;

    let system = directive;
    system += memoriesBlock(memories);
    system += behaviorsBlock(behaviors);
    system += VOICE_TAGS_RULE;

    const grokMessages: WireMessage[] = [
      { role: "system", content: system },
      ...(turnHistory ?? []).map((t) => ({ role: t.role === "user" ? "user" : "assistant", content: t.content })),
      { role: "user", content: userTranscript },
    ];

    const replyText = (await callGrok(grokMessages, 350, conversationId)).trim();

    if (!ELEVENLABS_API_KEY) return json({ error: "ELEVENLABS_API_KEY not configured" }, 500);
    const voiceId = character?.voice_id || elevenVoiceIdFor(personalityRole, vibe);
    const elevenResp = await fetch(`${ELEVENLABS_TTS_URL}/${voiceId}`, {
      method: "POST",
      headers: { "xi-api-key": ELEVENLABS_API_KEY, "Content-Type": "application/json" },
      body: JSON.stringify({ text: replyText, model_id: "eleven_v3" }),
    });
    if (!elevenResp.ok) return json({ error: `ElevenLabs TTS error: ${await elevenResp.text()}` }, 502);
    const audioBytes = new Uint8Array(await elevenResp.arrayBuffer());
    const audioUrl = await uploadCallAudio(audioBytes, callSessionId);

    await db.from("call_turns").insert([
      { call_session_id: callSessionId, role: "user", content: userTranscript },
      { call_session_id: callSessionId, role: "assistant", content: replyText, audio_url: audioUrl },
    ]);

    return json({ replyText, audioBase64: bytesToBase64(audioBytes) });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
```

- [ ] **Step 2: Deploy and smoke-test**

Run: `npx supabase functions deploy voice-call-turn --project-ref ohpvhgwjmrfjclnumgnm`
Expected: `"message":"Deployed Functions."`.

Run: `npx supabase functions list --project-ref ohpvhgwjmrfjclnumgnm | grep voice-call-turn`
Expected: shows the function with a recent updated timestamp.

- [ ] **Step 3: Commit**

```bash
git add supabase/functions/voice-call-turn/index.ts
git commit -m "feat(backend): add voice-call-turn edge function"
```

---

### Task 6: `voice-call-checkpoint` edge function

**Files:**
- Create: `supabase/functions/voice-call-checkpoint/index.ts`

**Interfaces:**
- Consumes: `call_sessions` (Task 3).
- Produces: `POST /voice-call-checkpoint` — input `{callSessionId: string, elapsedSeconds: number}`, output `{ok: boolean}` (200) — consumed by Task 9/10.

- [ ] **Step 1: Write the function**

Create `supabase/functions/voice-call-checkpoint/index.ts`:

```typescript
// supabase/functions/voice-call-checkpoint/index.ts
//
// Called every ~5s by the client during an active call. Records the elapsed
// time as a crash-recovery marker (no charge here — billing settles once in
// voice-call-end) and checks whether the projected cost would exceed the
// user's balance, so the client can end the call before going negative.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

const TOKENS_PER_SECOND = 3;

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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);

    const body = await req.json();
    const callSessionId: string = body.callSessionId;
    const elapsedSeconds: number = Number(body.elapsedSeconds) || 0;
    if (!callSessionId) return json({ error: "callSessionId required" }, 400);

    const { data: session } = await db.from("call_sessions")
      .select("id, user_id, status").eq("id", callSessionId).maybeSingle();
    if (!session || session.user_id !== uid || session.status !== "active") {
      return json({ ok: false }, 400);
    }

    await db.from("call_sessions")
      .update({ last_checkpoint_seconds: elapsedSeconds })
      .eq("id", callSessionId);

    const { data: balanceRow } = await db.from("token_balances").select("balance").eq("user_id", uid).maybeSingle();
    const projectedCost = elapsedSeconds * TOKENS_PER_SECOND;
    if (projectedCost > (balanceRow?.balance ?? 0)) {
      return json({ ok: false });
    }
    return json({ ok: true });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
```

- [ ] **Step 2: Deploy and smoke-test**

Run: `npx supabase functions deploy voice-call-checkpoint --project-ref ohpvhgwjmrfjclnumgnm`
Expected: `"message":"Deployed Functions."`.

- [ ] **Step 3: Commit**

```bash
git add supabase/functions/voice-call-checkpoint/index.ts
git commit -m "feat(backend): add voice-call-checkpoint edge function"
```

---

### Task 7: `voice-call-end` edge function

**Files:**
- Create: `supabase/functions/voice-call-end/index.ts`

**Interfaces:**
- Consumes: `call_sessions`/`call_turns` (Task 3).
- Produces: `POST /voice-call-end` — input `{callSessionId: string, actualElapsedSeconds: number}`, output `{tokensCharged: number, newBalance: number}` (200) — consumed by Task 9/10.

- [ ] **Step 1: Write the function**

Create `supabase/functions/voice-call-end/index.ts`:

```typescript
// supabase/functions/voice-call-end/index.ts
//
// Ends a call: one-time charge (elapsedSeconds * 3 tokens), marks the
// session ended, and runs one-shot memory extraction over the full
// call_turns transcript — same JSON-extraction pattern chat/index.ts's
// periodic summarization uses — appending any new durable facts to the
// character's existing `memories` (bkz. design spec, chat/index.ts's
// "newMemories" summarization block).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const XAI_API_KEY = Deno.env.get("XAI_API_KEY") ?? "";
const XAI_URL = "https://api.x.ai/v1/chat/completions";
const MODEL = "grok-4-1-fast-non-reasoning";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

const TOKENS_PER_SECOND = 3;

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

function extractJson(raw: string): any | null {
  const match = raw.match(/\{[\s\S]*\}/);
  if (!match) return null;
  try { return JSON.parse(match[0]); } catch { return null; }
}

async function callGrok(messages: { role: string; content: string }[], maxTokens: number): Promise<string> {
  const resp = await fetch(XAI_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${XAI_API_KEY}` },
    body: JSON.stringify({ model: MODEL, messages, temperature: 0.7, max_tokens: maxTokens }),
  });
  if (!resp.ok) throw new Error(`LLM ${resp.status}: ${await resp.text()}`);
  const data = await resp.json();
  return data?.choices?.[0]?.message?.content ?? "";
}

async function extractAndStoreMemories(conversationId: string, callSessionId: string) {
  const { data: turns } = await db.from("call_turns")
    .select("role, content").eq("call_session_id", callSessionId).order("created_at", { ascending: true });
  if (!turns || turns.length === 0) return;

  const { data: existingMemories } = await db.from("memories")
    .select("content").eq("conversation_id", conversationId).order("created_at", { ascending: true });
  const existingMemoryLines = (existingMemories ?? []).map((m) => `- ${m.content}`).join("\n") || "(none yet)";

  const transcript = turns.map((t) => `${t.role === "user" ? "User" : "You"}: ${t.content}`).join("\n");

  const raw = await callGrok([
    {
      role: "system",
      content:
        "Extract NEW durable atomic facts worth permanently remembering (name, preferences, " +
        "promises, key relationship moments) from this voice call transcript, that are NOT " +
        "already covered by the existing memories list you'll be given — do not repeat anything " +
        "already in that list, even reworded. If there's nothing new, return an empty array. " +
        'Respond with ONLY this JSON shape, nothing else: {"newMemories":["fact one","fact two"]}',
    },
    {
      role: "user",
      content: `Existing memories (do not repeat these):\n${existingMemoryLines}\n\nCall transcript:\n${transcript}\n\nJSON:`,
    },
  ], 500);

  const parsed = extractJson(raw);
  const newMemories: string[] = Array.isArray(parsed?.newMemories)
    ? parsed.newMemories.filter((m: unknown): m is string => typeof m === "string" && m.trim().length > 0)
    : [];
  if (newMemories.length > 0) {
    await db.from("memories").insert(
      newMemories.map((content) => ({ conversation_id: conversationId, content: content.trim() })),
    );
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);

    const body = await req.json();
    const callSessionId: string = body.callSessionId;
    const actualElapsedSeconds: number = Number(body.actualElapsedSeconds) || 0;
    if (!callSessionId) return json({ error: "callSessionId required" }, 400);

    const { data: session } = await db.from("call_sessions")
      .select("id, user_id, conversation_id, status").eq("id", callSessionId).maybeSingle();
    if (!session || session.user_id !== uid) return json({ error: "invalid_call_session" }, 400);
    if (session.status === "ended") {
      const { data: balanceRow } = await db.from("token_balances").select("balance").eq("user_id", uid).maybeSingle();
      return json({ tokensCharged: 0, newBalance: balanceRow?.balance ?? 0 });
    }

    const tokensCharged = Math.round(actualElapsedSeconds * TOKENS_PER_SECOND);
    let newBalance = 0;
    if (tokensCharged > 0) {
      await db.rpc("charge_tokens", { p_user_id: uid, p_amount: tokensCharged, p_reason: "voice_call" });
    }
    const { data: balanceRow } = await db.from("token_balances").select("balance").eq("user_id", uid).maybeSingle();
    newBalance = balanceRow?.balance ?? 0;

    await db.from("call_sessions")
      .update({ status: "ended", ended_at: new Date().toISOString(), tokens_charged: tokensCharged })
      .eq("id", callSessionId);

    if (session.conversation_id) {
      try {
        await extractAndStoreMemories(session.conversation_id, callSessionId);
      } catch (e) {
        console.error("memory extraction failed:", String(e));
      }
    }

    return json({ tokensCharged, newBalance });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
```

- [ ] **Step 2: Deploy and smoke-test**

Run: `npx supabase functions deploy voice-call-end --project-ref ohpvhgwjmrfjclnumgnm`
Expected: `"message":"Deployed Functions."`.

Run: `npx supabase functions list --project-ref ohpvhgwjmrfjclnumgnm`
Expected: `voice-call-start`, `voice-call-turn`, `voice-call-checkpoint`, `voice-call-end` all listed with recent timestamps.

- [ ] **Step 3: Commit**

```bash
git add supabase/functions/voice-call-end/index.ts
git commit -m "feat(backend): add voice-call-end edge function with memory extraction"
```

---

### Task 8: Client `Config.swift` + `CallService.swift`

**Files:**
- Modify: `Plumm/Config.swift`
- Create: `Plumm/Services/CallService.swift`

**Interfaces:**
- Consumes: `Config.supabaseURL`, `UserDefaultsManager.shared.accessToken`, `Config.supabaseAnonKey` (existing).
- Produces: `CallService.start(characterId: String, conversationId: String?) async throws -> String` (returns `callSessionId`), `CallService.sendTurn(callSessionId: String, transcript: String, reviewMode: Bool) async throws -> (replyText: String, audioData: Data)`, `CallService.checkpoint(callSessionId: String, elapsedSeconds: Double) async throws -> Bool`, `CallService.end(callSessionId: String, actualElapsedSeconds: Double) async throws -> (tokensCharged: Int, newBalance: Int)`, error type `CallServiceError.insufficientTokens` / `CallServiceError.badStatus(Int, String)` — consumed by Task 10 (`CallViewModel`).

- [ ] **Step 1: Add the four endpoint URLs to `Config.swift`**

In `Plumm/Config.swift`, find:

```swift
    static var devUpdateCharacterFunctionURL: URL {
        URL(string: "\(supabaseURL)/functions/v1/dev-update-character")!
    }
}
```

Replace with:

```swift
    static var devUpdateCharacterFunctionURL: URL {
        URL(string: "\(supabaseURL)/functions/v1/dev-update-character")!
    }

    // MARK: Real-time voice call (bkz. CallService, CallViewModel)

    static var voiceCallStartFunctionURL: URL {
        URL(string: "\(supabaseURL)/functions/v1/voice-call-start")!
    }
    static var voiceCallTurnFunctionURL: URL {
        URL(string: "\(supabaseURL)/functions/v1/voice-call-turn")!
    }
    static var voiceCallCheckpointFunctionURL: URL {
        URL(string: "\(supabaseURL)/functions/v1/voice-call-checkpoint")!
    }
    static var voiceCallEndFunctionURL: URL {
        URL(string: "\(supabaseURL)/functions/v1/voice-call-end")!
    }
}
```

- [ ] **Step 2: Write `CallService.swift`**

Create `Plumm/Services/CallService.swift`:

```swift
//
//  CallService.swift
//  Real-time voice call Edge Functions ile konuşur (voice-call-start/turn/checkpoint/end).
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

    func start(characterId: String, conversationId: String?) async throws -> String {
        var body: [String: Any] = ["characterId": characterId]
        if let conversationId { body["conversationId"] = conversationId }
        let (data, http) = try await request(url: Config.voiceCallStartFunctionURL, body: body)
        if http.statusCode == 402 { throw CallServiceError.insufficientTokens }
        guard http.statusCode == 200 else {
            throw CallServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct Response: Decodable { let callSessionId: String }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw CallServiceError.decoding }
        return decoded.callSessionId
    }

    func sendTurn(callSessionId: String, transcript: String, reviewMode: Bool) async throws -> (replyText: String, audioData: Data) {
        let body: [String: Any] = [
            "callSessionId": callSessionId, "userTranscript": transcript, "reviewMode": reviewMode,
        ]
        let (data, http) = try await request(url: Config.voiceCallTurnFunctionURL, body: body)
        guard http.statusCode == 200 else {
            throw CallServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct Response: Decodable { let replyText: String; let audioBase64: String }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let audioData = Data(base64Encoded: decoded.audioBase64)
        else { throw CallServiceError.decoding }
        return (decoded.replyText, audioData)
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

- [ ] **Step 3: Verify it compiles**

Run: `xcodebuild build -project Plumm.xcodeproj -scheme Plumm -destination 'generic/platform=iOS Simulator' -disableAutomaticPackageResolution 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **` (or, if this hangs on package resolution per `[[unverified_merge_2026_07_28]]`, note it and continue — full build verification happens at Task 12).

- [ ] **Step 4: Commit**

```bash
git add Plumm/Config.swift Plumm/Services/CallService.swift
git commit -m "feat(client): add CallService networking layer for voice calls"
```

---

### Task 9: `SpeechRecognizer` — opt-out session configuration for call reuse

`CallViewModel` (Task 10) needs full-duplex audio (`.playAndRecord` + `.voiceChat`, configured once for the whole call) so barge-in can work — but `SpeechRecognizer.start()` currently always calls `session.setCategory(.record, ...)`, which would silently break duplex every time it's invoked mid-call. Add an opt-out so the existing tap-to-record voice-note flow (`ChatView`) is untouched while `CallViewModel` can reuse the same proven STT engine.

**Files:**
- Modify: `Plumm/Services/SpeechRecognizer.swift:46-58`

**Interfaces:**
- Produces: `SpeechRecognizer.start(configuresSession: Bool = true) -> Bool` — consumed by Task 10.

- [ ] **Step 1: Add the parameter**

Find:

```swift
    @discardableResult
    func start() -> Bool {
        guard !isRecording else { return true }
        transcript = ""
        recordedFileURL = nil

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return false
        }
```

Replace:

```swift
    /// `configuresSession: false` skips the `.record`-category session setup —
    /// used by CallViewModel, which owns a single `.playAndRecord`/`.voiceChat`
    /// session for the whole call (duplex: listens while the AI is speaking for
    /// barge-in). The normal tap-to-record voice-note flow (ChatView) always
    /// passes the default `true`, unchanged.
    @discardableResult
    func start(configuresSession: Bool = true) -> Bool {
        guard !isRecording else { return true }
        transcript = ""
        recordedFileURL = nil

        if configuresSession {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                return false
            }
        }
        lastStartConfiguredSession = configuresSession
```

Add the backing property next to the other `private var` declarations near the top of the class:

```swift
    private var recorder: AVAudioRecorder?
    /// Mirrors the `configuresSession` a caller passed to the most recent
    /// `start()` — `stop()` reads this so it only deactivates the shared
    /// audio session when THIS instance is the one that activated it.
    /// Without this, CallViewModel's mid-call `recognizer.cancel()` (barge-in
    /// cleanup, mute) would deactivate the whole call's duplex session, not
    /// just this recognition pass.
    private var lastStartConfiguredSession = true
```

- [ ] **Step 2: Stop `stop()` from deactivating a session it didn't configure**

Find, in `stop()`:

```swift
        recorder?.stop()
        recordedFileURL = recorder?.url
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
```

Replace:

```swift
        recorder?.stop()
        recordedFileURL = recorder?.url
        recorder = nil
        if lastStartConfiguredSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
```

- [ ] **Step 3: Verify the existing call site still compiles unchanged**

Run: `grep -n "recognizer.start()\|\.start()" Plumm/Views/ChatView.swift`
Expected: existing call site(s) call `.start()` with no arguments — still valid since `configuresSession` defaults to `true`, so `stop()`'s existing deactivate-on-stop behavior is unchanged for every caller except `CallViewModel`.

Run: `git diff Plumm/Services/SpeechRecognizer.swift`
Expected: the new `lastStartConfiguredSession` property, `start()`'s signature + `if configuresSession { ... }` wrapper + the trailing assignment, and `stop()`'s `if lastStartConfiguredSession { ... }` wrapper — nothing else in the file touched (tap install, recorder, `audioEngine.start()`, recognition task all unchanged).

- [ ] **Step 4: Commit**

```bash
git add Plumm/Services/SpeechRecognizer.swift
git commit -m "feat(client): let SpeechRecognizer skip session setup for call reuse"
```

---

### Task 10: `CallViewModel.swift` — state machine + barge-in

**Files:**
- Create: `Plumm/ViewModels/CallViewModel.swift`

**Interfaces:**
- Consumes: `CallService` (Task 8), `SpeechRecognizer.start(configuresSession:)` (Task 9), `TokenStore` (existing), `Character` (existing model).
- Produces: `CallViewModel` with `var state: CallState` (`.idle/.listening/.thinking/.speaking/.ended`), `var isMuted: Bool`, `func startCall() async`, `func endCall() async`, `func toggleMute()` — consumed by Task 11 (`VoiceCallView`).

- [ ] **Step 1: Write the view model**

Create `Plumm/ViewModels/CallViewModel.swift`:

```swift
//
//  CallViewModel.swift
//  Real-time voice call durumu: listening -> thinking -> speaking, barge-in destekli.
//

import Foundation
import AVFoundation
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
final class CallViewModel: NSObject, AVAudioPlayerDelegate {
    let character: Character
    let conversationId: String?
    var tokenStore: TokenStore?

    var state: CallState = .idle
    var isMuted: Bool = false
    var errorMessage: String?

    private let service = CallService()
    private let recognizer = SpeechRecognizer()
    private var player: AVAudioPlayer?

    private var callSessionId: String?
    private var callStartedAt: Date?
    private var checkpointTask: Task<Void, Never>?
    private var turnLoopTask: Task<Void, Never>?
    private var bargeInWatchTask: Task<Void, Never>?

    init(character: Character, conversationId: String?) {
        self.character = character
        self.conversationId = conversationId
    }

    private var elapsedSeconds: Double {
        guard let callStartedAt else { return 0 }
        return Date().timeIntervalSince(callStartedAt)
    }

    func startCall() async {
        await recognizer.requestAuthorization()
        guard recognizer.authorized else {
            errorMessage = String(localized: "Microphone/Speech access is required for calls.")
            state = .ended(reason: .error)
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers, .allowBluetooth, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = String(localized: "Couldn't start the call's audio session.")
            state = .ended(reason: .error)
            return
        }

        do {
            callSessionId = try await service.start(characterId: character.id, conversationId: conversationId)
        } catch CallServiceError.insufficientTokens {
            state = .ended(reason: .insufficientTokens)
            return
        } catch {
            errorMessage = String(localized: "Couldn't start the call.")
            state = .ended(reason: .error)
            return
        }

        callStartedAt = Date()
        startCheckpointLoop()
        turnLoopTask = Task { await runListenTurn() }
    }

    func endCall() async {
        checkpointTask?.cancel()
        turnLoopTask?.cancel()
        bargeInWatchTask?.cancel()
        recognizer.cancel()
        player?.stop()
        player = nil

        let finalElapsed = elapsedSeconds
        if let callSessionId {
            if let result = try? await service.end(callSessionId: callSessionId, actualElapsedSeconds: finalElapsed) {
                tokenStore?.setBalance(result.newBalance)
            }
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if case .ended = state {} else { state = .ended(reason: .userEnded) }
    }

    func toggleMute() {
        isMuted.toggle()
        if isMuted { recognizer.cancel() }
    }

    // MARK: - Turn loop

    private func runListenTurn() async {
        guard !isMuted else {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !Task.isCancelled { turnLoopTask = Task { await self.runListenTurn() } }
            return
        }
        state = .listening
        recognizer.start(configuresSession: false)

        while recognizer.isRecording, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        guard !Task.isCancelled else { return }

        let transcript = recognizer.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty, let callSessionId else {
            turnLoopTask = Task { await self.runListenTurn() }
            return
        }

        state = .thinking
        do {
            let result = try await service.sendTurn(
                callSessionId: callSessionId, transcript: transcript, reviewMode: ReviewModeService.isEnabledSnapshot
            )
            guard !Task.isCancelled else { return }
            await speak(result.audioData)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = String(localized: "That turn failed — try speaking again.")
            turnLoopTask = Task { await self.runListenTurn() }
        }
    }

    private func speak(_ audioData: Data) async {
        state = .speaking
        do {
            let p = try AVAudioPlayer(data: audioData)
            p.delegate = self
            player = p
            p.play()
        } catch {
            turnLoopTask = Task { await self.runListenTurn() }
            return
        }

        // Barge-in watcher: reuse the SAME recognizer instance concurrently
        // with playback (duplex session from startCall handles echo
        // cancellation) — any non-trivial partial transcript while `speaking`
        // means the user started talking over the AI.
        recognizer.start(configuresSession: false)
        bargeInWatchTask = Task {
            while state == .speaking, !Task.isCancelled {
                if recognizer.transcript.trimmingCharacters(in: .whitespacesAndNewlines).count > 2 {
                    player?.stop()
                    player = nil
                    state = .listening
                    // Recognizer keeps running — its current session becomes
                    // this next turn's capture, picked up by the poll loop below.
                    while recognizer.isRecording, !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                    }
                    guard !Task.isCancelled else { return }
                    let transcript = recognizer.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !transcript.isEmpty, let callSessionId else {
                        turnLoopTask = Task { await self.runListenTurn() }
                        return
                    }
                    state = .thinking
                    do {
                        let result = try await service.sendTurn(
                            callSessionId: callSessionId, transcript: transcript, reviewMode: ReviewModeService.isEnabledSnapshot
                        )
                        await speak(result.audioData)
                    } catch {
                        errorMessage = String(localized: "That turn failed — try speaking again.")
                        turnLoopTask = Task { await self.runListenTurn() }
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.state == .speaking else { return }
            self.bargeInWatchTask?.cancel()
            self.recognizer.cancel() // discard the barge-in listener session, start fresh next turn
            self.player = nil
            self.turnLoopTask = Task { await self.runListenTurn() }
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

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild build -project Plumm.xcodeproj -scheme Plumm -destination 'generic/platform=iOS Simulator' -disableAutomaticPackageResolution 2>&1 | tail -40`
Expected: `** BUILD SUCCEEDED **`, or a specific compile error to fix before moving on (e.g. `ReviewModeService.isEnabledSnapshot`'s exact spelling — verify with `grep -rn "isEnabledSnapshot" Plumm/` if this fails).

- [ ] **Step 3: Commit**

```bash
git add Plumm/ViewModels/CallViewModel.swift
git commit -m "feat(client): add CallViewModel state machine with barge-in"
```

---

### Task 11: `VoiceCallView.swift`

**Files:**
- Create: `Plumm/Views/VoiceCallView.swift`

**Interfaces:**
- Consumes: `CallViewModel` (Task 10), `Character` (existing).
- Produces: `VoiceCallView(character: Character, conversationId: String?, tokenStore: TokenStore)` — consumed by Task 12.

- [ ] **Step 1: Write the view**

Create `Plumm/Views/VoiceCallView.swift`:

```swift
//
//  VoiceCallView.swift
//  Tam ekran sesli arama — avatar + durum göstergesi, altyazı yok (bkz. design spec).
//

import SwiftUI

struct VoiceCallView: View {
    @State private var viewModel: CallViewModel
    @Environment(\.dismiss) private var dismiss
    let tokenStore: TokenStore

    init(character: Character, conversationId: String?, tokenStore: TokenStore) {
        _viewModel = State(initialValue: CallViewModel(character: character, conversationId: conversationId))
        self.tokenStore = tokenStore
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x1A0F1F), Color(hex: 0x2B1730)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(AppColor.pink.opacity(0.25))
                        .frame(width: 220, height: 220)
                        .scaleEffect(viewModel.state == .speaking ? 1.08 : 1.0)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: viewModel.state == .speaking)

                    CharacterAvatarView(character: viewModel.character)
                        .frame(width: 180, height: 180)
                        .clipShape(Circle())
                }

                Text(viewModel.character.name)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)

                Text(statusLabel)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))

                Spacer()

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 32)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 40) {
                    Button { viewModel.toggleMute() } label: {
                        Image(systemName: viewModel.isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                            .background(.white.opacity(0.15), in: Circle())
                    }

                    Button {
                        Task {
                            await viewModel.endCall()
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .background(Color.red, in: Circle())
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear { Task { await viewModel.startCall() } }
        .onChange(of: viewModel.state) { _, newState in
            if case .ended = newState {
                Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    dismiss()
                }
            }
        }
        .onDisappear {
            viewModel.tokenStore = tokenStore
            Task { await viewModel.endCall() }
        }
        .task { viewModel.tokenStore = tokenStore }
    }

    private var statusLabel: String {
        switch viewModel.state {
        case .idle: return String(localized: "Connecting…")
        case .listening: return String(localized: "Listening…")
        case .thinking: return String(localized: "Thinking…")
        case .speaking: return String(localized: "Speaking…")
        case .ended(let reason):
            switch reason {
            case .userEnded: return String(localized: "Call ended")
            case .insufficientTokens: return String(localized: "Out of tokens — call ended")
            case .error: return String(localized: "Call failed")
            }
        }
    }
}
```

- [ ] **Step 2: Verify `CharacterAvatarView` exists with this signature**

Run: `grep -rn "struct CharacterAvatarView" Plumm/`
Expected: a view taking a `Character` (or `character:` label) that this file's usage matches. If the actual name/signature differs, adjust `VoiceCallView`'s avatar usage to match the real component (e.g. it may take an image URL instead of the whole `Character` — check `Plumm/Views/ChatView.swift`'s `avatarWithLevel` for the exact pattern already used there and mirror it).

- [ ] **Step 3: Verify it compiles**

Run: `xcodebuild build -project Plumm.xcodeproj -scheme Plumm -destination 'generic/platform=iOS Simulator' -disableAutomaticPackageResolution 2>&1 | tail -40`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Plumm/Views/VoiceCallView.swift
git commit -m "feat(client): add VoiceCallView full-screen call UI"
```

---

### Task 12: Wire the call entry point into `ChatView`

**Files:**
- Modify: `Plumm/Views/ChatView.swift`

**Interfaces:**
- Consumes: `VoiceCallView` (Task 11).

- [ ] **Step 1: Add state + the phone button**

In `Plumm/Views/ChatView.swift`, find the `@State` block near the top (around line 24-30):

```swift
    @State private var showProfile = false
    @State private var showTokenStore = false
```

Replace:

```swift
    @State private var showProfile = false
    @State private var showTokenStore = false
    @State private var showVoiceCall = false
```

Then find the header's button row:

```swift
                if PurchaseService.shared.isPro {
                    TokenBadge(tokenStore: tokenStore) { showTokenStore = true }
                } else {
                    chatProButton
                }
                headerButton("gearshape.fill", menu: true)
```

Replace:

```swift
                headerButton("phone.fill", action: { showVoiceCall = true })
                if PurchaseService.shared.isPro {
                    TokenBadge(tokenStore: tokenStore) { showTokenStore = true }
                } else {
                    chatProButton
                }
                headerButton("gearshape.fill", menu: true)
```

- [ ] **Step 2: Add the full-screen cover**

Find where existing full-screen presentations are declared on the root view (search for an existing `.fullScreenCover` or `.sheet(isPresented: $showProfile)` in `ChatView.swift` to place this alongside them):

Run: `grep -n "\.sheet(isPresented: \$showProfile\|\.fullScreenCover" Plumm/Views/ChatView.swift`

Add, immediately after that modifier:

```swift
        .fullScreenCover(isPresented: $showVoiceCall) {
            VoiceCallView(character: viewModel.character, conversationId: nil, tokenStore: tokenStore)
        }
```

- [ ] **Step 3: Verify the conversationId gap**

`VoiceCallView` is passed `conversationId: nil` above because `ChatView`/`ChatViewModel` don't currently track a server-side `conversationId` string on the client (the server resolves/creates it per-request, per `chat/index.ts`'s "GEÇMİŞ modu" comment). Run: `grep -n "conversationId" Plumm/ViewModels/ChatViewModel.swift` to confirm there's no existing client-held conversation id to pass instead. Passing `nil` is correct and matches `voice-call-start`'s `conversationId` field being optional (Task 4) — the call session just won't have a `conversation_id` link, and `voice-call-end`'s memory-extraction step (Task 7) will no-op for this call (guarded by `if (session.conversation_id)`). Note this as a known limitation, not a bug to fix in this plan (fixing it would require a broader client-side conversation-id-tracking change out of scope for this spec).

- [ ] **Step 4: Verify it compiles**

Run: `xcodebuild build -project Plumm.xcodeproj -scheme Plumm -destination 'generic/platform=iOS Simulator' -disableAutomaticPackageResolution 2>&1 | tail -40`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Plumm/Views/ChatView.swift
git commit -m "feat(client): wire voice call entry point into ChatView header"
```

---

### Task 13: Manual end-to-end smoke test

**Files:** none (manual verification only)

- [ ] **Step 1: Run the app on a physical device or simulator with mic access**

Build and run `Plumm` (device recommended — simulator mic input is unreliable for `SFSpeechRecognizer`).

- [ ] **Step 2: Start a call**

Open a character's chat, tap the new phone icon. Expected: full-screen call view appears, state moves `Connecting… → Listening…`.

- [ ] **Step 3: Speak a turn**

Say something, pause. Expected: state moves `Listening… → Thinking… → Speaking…`, AI's voice plays back.

- [ ] **Step 4: Test barge-in**

While the AI is speaking, start talking. Expected: playback stops immediately, state returns to `Listening…`.

- [ ] **Step 5: End the call**

Tap the red end-call button. Expected: call view dismisses; check Supabase (`call_sessions`/`call_turns` tables via dashboard) to confirm the session is `status='ended'` with a non-zero `tokens_charged`, and `call_turns` has the full transcript.

- [ ] **Step 6: Verify token balance updated**

Check the token badge in the main chat header reflects the deduction (`tokensCharged` from Task 7's response, applied via `tokenStore.setBalance`).

- [ ] **Step 7: Report results**

If any step fails, note which one and the exact error/behavior — do not attempt further fixes beyond this plan without checking in first (per this repo's "stop when blocked" convention for irreversible/unclear situations).
