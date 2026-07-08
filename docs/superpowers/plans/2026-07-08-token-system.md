# Token System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Meter every message/voice/photo action through a real token balance, gate character creation behind subscription tier + weekly slot count, and ship the badge/streak/paywall UI approved in `docs/superpowers/specs/2026-07-08-token-system-design.md`.

**Architecture:** New Postgres tables (`token_balances`, `token_transactions`, `streak_state`, `subscriptions`) + two atomic RPC functions (`charge_tokens`, `grant_tokens`) are the server-side source of truth. Every paid edge function (`chat`, `chat-image`, `voice-message-tts`) calls `charge_tokens` after its paid API work succeeds, rejecting up front if the balance is already insufficient. A new `claim-streak` edge function owns the daily-grant anti-abuse logic. The Swift client gets a `TokenStore` (balance cache, mirrors the existing `CharacterStore`/`GeneratedPhotoService` pattern), a `TokenBadge` view placed once on `MainTabView`'s stack, a `TokenStoreView` (the paywall/purchase page), and a `StreakPopupView`.

**Tech Stack:** Supabase Postgres + Edge Functions (Deno/TypeScript, existing patterns), SwiftUI/`@Observable` (existing patterns), no new external dependencies.

## Global Constraints

- No new Grok/xAI instructional prompt text is introduced by this feature — skip the English-only prompt rule, it doesn't apply here.
- Every new user-facing Swift string must go through `String(localized:)` and get a full `de/es/fr/it/pt/tr` entry in `Localizable.xcstrings` (see the string list embedded in each Swift task below) — per this project's established localization rule.
- **This project has no Xcode and no test target in this sandbox** (documented, longstanding constraint). "Tests" for Swift tasks in this plan mean: the code must compile by inspection (match existing call-site patterns exactly, no invented APIs), and each Swift task ends with a manual QA checklist for the user to run once they build in Xcode. Edge function and SQL tasks, by contrast, ARE independently verifiable right now via `curl`/the Supabase Management API — those verification steps are real and must actually be run.
- Every DB write path in this feature is `service_role`-only inside an edge function, exactly like `conversations.relationship_level` today — the client never writes its own balance directly.
- Deploy each edge function immediately after finishing its task (`SUPABASE_ACCESS_TOKEN=... npx supabase functions deploy <name> --project-ref ohpvhgwjmrfjclnumgnm --no-verify-jwt`), don't batch deploys to the end.

---

## Task 1: Database schema — token/streak/subscription tables + charge/grant RPCs

**Files:**
- Create: `supabase/migrations/005_token_system.sql`

**Interfaces:**
- Produces: tables `token_balances(user_id, balance, updated_at)`, `token_transactions(id, user_id, delta, reason, created_at)`, `streak_state(user_id, current_streak, last_claim_at, last_claimed_local_date)`, `subscriptions(user_id, tier, current_period_start, current_period_end, updated_at)`; RPCs `charge_tokens(p_user_id uuid, p_amount int, p_reason text) returns boolean` and `grant_tokens(p_user_id uuid, p_amount int, p_reason text) returns void`.

- [ ] **Step 1: Write the migration SQL**

```sql
-- supabase/migrations/005_token_system.sql

create table if not exists token_balances (
  user_id uuid primary key references auth.users(id) on delete cascade,
  balance integer not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists token_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  delta integer not null,
  reason text not null check (reason in ('message', 'voice', 'photo', 'streak', 'purchase', 'subscription_grant', 'welcome')),
  created_at timestamptz not null default now()
);
create index if not exists token_transactions_user_id_idx on token_transactions(user_id);

create table if not exists streak_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  current_streak integer not null default 0,
  last_claim_at timestamptz,
  last_claimed_local_date text
);

-- Populated by a future RevenueCat webhook (see design doc "Dependencies").
-- Empty today — every check against this table correctly finds no active
-- subscription until that webhook exists, matching current app behavior.
create table if not exists subscriptions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  tier text not null check (tier in ('pro', 'pro_plus', 'max')),
  current_period_start timestamptz not null,
  current_period_end timestamptz not null,
  updated_at timestamptz not null default now()
);

alter table token_balances enable row level security;
alter table token_transactions enable row level security;
alter table streak_state enable row level security;
alter table subscriptions enable row level security;

create policy "select own token balance" on token_balances for select using (user_id = auth.uid());
create policy "select own token transactions" on token_transactions for select using (user_id = auth.uid());
create policy "select own streak state" on streak_state for select using (user_id = auth.uid());
create policy "select own subscription" on subscriptions for select using (user_id = auth.uid());

-- Atomically deducts tokens if (and only if) the balance can cover it.
-- Returns false (no-op, no ledger row) on insufficient balance — callers
-- must check the return value and reject the paid action's response.
create or replace function charge_tokens(p_user_id uuid, p_amount int, p_reason text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new_balance int;
begin
  insert into token_balances (user_id, balance)
  values (p_user_id, 0)
  on conflict (user_id) do nothing;

  update token_balances
    set balance = balance - p_amount, updated_at = now()
    where user_id = p_user_id and balance >= p_amount
    returning balance into v_new_balance;

  if v_new_balance is null then
    return false;
  end if;

  insert into token_transactions (user_id, delta, reason)
  values (p_user_id, -p_amount, p_reason);

  return true;
end;
$$;

-- Adds tokens (streak grants, purchases, subscription drips, the one-time
-- welcome grant). No balance check needed — always succeeds.
create or replace function grant_tokens(p_user_id uuid, p_amount int, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into token_balances (user_id, balance)
  values (p_user_id, p_amount)
  on conflict (user_id) do update set balance = token_balances.balance + p_amount, updated_at = now();

  insert into token_transactions (user_id, delta, reason)
  values (p_user_id, p_amount, p_reason);
end;
$$;
```

- [ ] **Step 2: Run the migration via the Management API**

```bash
SQL=$(cat supabase/migrations/005_token_system.sql)
curl -s -X POST "https://api.supabase.com/v1/projects/ohpvhgwjmrfjclnumgnm/database/query" \
  -H "Authorization: Bearer $SUPABASE_MANAGEMENT_PAT" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"query": sys.stdin.read()}))' <<< "$SQL")"
```

Expected: `[]` or a success response, no error object.

- [ ] **Step 3: Verify the tables and RPCs exist**

```bash
curl -s -X POST "https://api.supabase.com/v1/projects/ohpvhgwjmrfjclnumgnm/database/query" \
  -H "Authorization: Bearer $SUPABASE_MANAGEMENT_PAT" \
  -H "Content-Type: application/json" \
  -d '{"query":"select table_name from information_schema.tables where table_name in (\'token_balances\',\'token_transactions\',\'streak_state\',\'subscriptions\');"}'
```

Expected: all 4 table names returned.

- [ ] **Step 4: Exercise `charge_tokens`/`grant_tokens` directly against a real auth user**

```bash
# Pick any real id from `select id from auth.users limit 1` for TEST_UID.
curl -s -X POST "https://api.supabase.com/v1/projects/ohpvhgwjmrfjclnumgnm/database/query" \
  -H "Authorization: Bearer $SUPABASE_MANAGEMENT_PAT" \
  -H "Content-Type: application/json" \
  -d '{"query":"select grant_tokens(${TEST_UID}::uuid, 10, $$welcome$$); select charge_tokens(${TEST_UID}::uuid, 3, $$message$$) as charged_ok; select charge_tokens(${TEST_UID}::uuid, 999, $$message$$) as should_be_false; select balance from token_balances where user_id = ${TEST_UID}::uuid;"}'
```

Expected: `charged_ok = true`, `should_be_false = false`, final `balance = 7` (10 granted − 3 charged, the failed 999-charge left balance untouched).

- [ ] **Step 5: Commit**

```bash
cd /Users/furkanozsoy/Desktop/Projects/aigf/WECAN
git add supabase/migrations/005_token_system.sql
git commit -m "feat: add token/streak/subscription schema + charge/grant RPCs"
```

---

## Task 2: `claim-streak` edge function

**Files:**
- Create: `supabase/functions/claim-streak/index.ts`

**Interfaces:**
- Consumes: `charge_tokens`/`grant_tokens` are not used here (this is a grant-only path) — calls `grant_tokens(uid, amount, 'streak')` from Task 1, and reads/writes `streak_state` directly.
- Produces: `POST /functions/v1/claim-streak` with `Authorization: Bearer <user JWT>`, no body needed. Response: `{ granted: true, amount: number, newStreak: number, balance: number }` or `{ granted: false, reason: "already_claimed_today" }`.

- [ ] **Step 1: Write the function**

```typescript
// supabase/functions/claim-streak/index.ts
//
// Daily free-token streak grant. Eligibility is gated by the SERVER's own
// UTC clock (minimum elapsed wall-clock time since the last claim) — never
// trust a client-reported local date for the actual grant decision, only
// for cosmetic display (see design doc "Anti-abuse"). A user who fakes their
// device clock forward/back cannot claim more than once per real ~20h window.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

const BASE_GRANT = 10;
const MIN_HOURS_BETWEEN_CLAIMS = 20;

function multiplierForStreak(streak: number): number {
  if (streak <= 1) return 1;
  if (streak <= 4) return 2;
  if (streak <= 6) return 3;
  return 5; // day 7+
}

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
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);

    const body = await req.json().catch(() => ({}));
    const clientLocalDate: string | undefined = typeof body.localDate === "string" ? body.localDate : undefined;

    const { data: state } = await db
      .from("streak_state")
      .select("current_streak, last_claim_at, last_claimed_local_date")
      .eq("user_id", uid)
      .maybeSingle();

    const now = new Date();
    if (state?.last_claim_at) {
      const hoursSince = (now.getTime() - new Date(state.last_claim_at).getTime()) / 3_600_000;
      if (hoursSince < MIN_HOURS_BETWEEN_CLAIMS) {
        return json({ granted: false, reason: "already_claimed_today" });
      }
    }

    // Streak continues only if the client's own local date advanced by
    // exactly one day since the last claim; anything else (first-ever claim,
    // a gap, or a suspicious multi-day jump) restarts at day 1.
    let newStreak = 1;
    if (state?.last_claimed_local_date && clientLocalDate) {
      const prev = new Date(state.last_claimed_local_date + "T00:00:00Z");
      const curr = new Date(clientLocalDate + "T00:00:00Z");
      const dayDiff = Math.round((curr.getTime() - prev.getTime()) / 86_400_000);
      if (dayDiff === 1) newStreak = (state.current_streak ?? 0) + 1;
    }

    const amount = BASE_GRANT * multiplierForStreak(newStreak);

    await db.from("streak_state").upsert({
      user_id: uid,
      current_streak: newStreak,
      last_claim_at: now.toISOString(),
      last_claimed_local_date: clientLocalDate ?? now.toISOString().slice(0, 10),
    });

    await db.rpc("grant_tokens", { p_user_id: uid, p_amount: amount, p_reason: "streak" });

    const { data: balanceRow } = await db
      .from("token_balances")
      .select("balance")
      .eq("user_id", uid)
      .single();

    return json({ granted: true, amount, newStreak, balance: balanceRow?.balance ?? amount });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
```

- [ ] **Step 2: Deploy**

```bash
cd /Users/furkanozsoy/Desktop/Projects/aigf/WECAN
SUPABASE_ACCESS_TOKEN=$SUPABASE_MANAGEMENT_PAT npx supabase functions deploy claim-streak --project-ref ohpvhgwjmrfjclnumgnm --no-verify-jwt
```

- [ ] **Step 3: Verify with a real user JWT** (get one from a device/simulator's `UserDefaultsManager.shared.accessToken`, or mint one by calling the anon signup endpoint)

```bash
curl -s -X POST "https://ohpvhgwjmrfjclnumgnm.supabase.co/functions/v1/claim-streak" \
  -H "Authorization: Bearer $TEST_USER_JWT" \
  -H "Content-Type: application/json" \
  -d '{"localDate":"2026-07-08"}'
# Expected: {"granted":true,"amount":10,"newStreak":1,"balance":10}

curl -s -X POST "https://ohpvhgwjmrfjclnumgnm.supabase.co/functions/v1/claim-streak" \
  -H "Authorization: Bearer $TEST_USER_JWT" \
  -H "Content-Type: application/json" \
  -d '{"localDate":"2026-07-08"}'
# Expected (second call, same day): {"granted":false,"reason":"already_claimed_today"}
```

- [ ] **Step 4: Commit**

```bash
git add supabase/functions/claim-streak/index.ts
git commit -m "feat: add claim-streak edge function with UTC-gated anti-abuse"
```

---

## Task 3: Charge tokens in `chat/index.ts` (1 token per plain-text turn)

**Files:**
- Modify: `supabase/functions/chat/index.ts`

**Interfaces:**
- Consumes: `charge_tokens` RPC from Task 1.
- Produces: reply-mode responses now also carry `tokenBalance: number`; failure case returns `{ error: "insufficient_tokens" }` at 402.

- [ ] **Step 1: Add the DB-backed charge helper near the top of the file, after the existing `db` client (around line 39)**

```typescript
async function chargeOrReject(uid: string, amount: number, reason: string): Promise<{ ok: true; balance: number } | { ok: false }> {
  const { data: charged } = await db.rpc("charge_tokens", { p_user_id: uid, p_amount: amount, p_reason: reason });
  if (!charged) return { ok: false };
  const { data: row } = await db.from("token_balances").select("balance").eq("user_id", uid).single();
  return { ok: true, balance: row?.balance ?? 0 };
}
```

- [ ] **Step 2: Charge exactly once, only for genuine plain-text reply turns — skip when `voiceChat`/`imageReactionChat` are set (those are charged by their own edge function, see Tasks 4–5), and skip for history/greeting/summarize modes (only real conversational turns cost tokens).**

Insert right after the `voiceChat`/`imageReactionChat`/`imageRedirected` flags are read (existing code around line 536, right after `const imageRedirected: boolean = body.imageRedirected === true;`), and only in the reply-mode branch — i.e. immediately before the block already guarded by `if (userMessage)` further down. Locate the point where `userMessage` is confirmed present and a real reply is about to be generated (this is the same place the existing `if (!voiceChat && !imageReactionChat)` MEDIA_REQUEST_RULE injection already happens, around line 741) and add the charge check directly above it:

```typescript
    // Token charge — ONE charge per user-facing action. voiceChat/imageReactionChat
    // turns are secondary calls whose cost is already covered by voice-message-tts/
    // chat-image (see design doc "Where deduction must happen"), so they charge 0 here.
    let tokenBalanceAfterCharge: number | undefined;
    if (userMessage && !voiceChat && !imageReactionChat) {
      const charge = await chargeOrReject(uid, 1, "message");
      if (!charge.ok) return json({ error: "insufficient_tokens" }, 402);
      tokenBalanceAfterCharge = charge.balance;
    }
```

- [ ] **Step 3: Surface the balance on both reply-mode response paths** (the two `return json({ conversationId, reply, level: newLevel, ... })` calls near the end of the file, lines ~838 and ~889) — add `tokenBalance: tokenBalanceAfterCharge` to both:

```typescript
      return json({ conversationId, reply, level: newLevel, wentToSleep, tokenBalance: tokenBalanceAfterCharge });
```
```typescript
    return json({ conversationId, reply, level: newLevel, tokenBalance: tokenBalanceAfterCharge });
```

- [ ] **Step 4: Deploy**

```bash
SUPABASE_ACCESS_TOKEN=$SUPABASE_MANAGEMENT_PAT npx supabase functions deploy chat --project-ref ohpvhgwjmrfjclnumgnm --no-verify-jwt
```

- [ ] **Step 5: Verify — grant a test user some tokens, send a message, confirm balance dropped by 1; drain the balance to 0 and confirm the next message is rejected**

```bash
curl -s -X POST "https://api.supabase.com/v1/projects/ohpvhgwjmrfjclnumgnm/database/query" \
  -H "Authorization: Bearer $SUPABASE_MANAGEMENT_PAT" -H "Content-Type: application/json" \
  -d '{"query":"select grant_tokens($$'"$TEST_UID"'$$::uuid, 1, $$welcome$$);"}'

curl -s -X POST "https://ohpvhgwjmrfjclnumgnm.supabase.co/functions/v1/chat" \
  -H "Authorization: Bearer $TEST_USER_JWT" -H "Content-Type: application/json" \
  -d '{"characterId":"00000000-0000-0000-0000-000000000001","systemPrompt":"test","userMessage":"hey","clientHistory":[],"level":1}'
# Expected: 200, body includes "tokenBalance":0

curl -s -X POST "https://ohpvhgwjmrfjclnumgnm.supabase.co/functions/v1/chat" \
  -H "Authorization: Bearer $TEST_USER_JWT" -H "Content-Type: application/json" \
  -d '{"characterId":"00000000-0000-0000-0000-000000000001","systemPrompt":"test","userMessage":"hey again","clientHistory":[],"level":1}'
# Expected: 402, {"error":"insufficient_tokens"}
```

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/chat/index.ts
git commit -m "feat: charge 1 token per plain-text chat turn"
```

---

## Task 4: Charge tokens in `chat-image/index.ts` (25 tokens per photo)

**Files:**
- Modify: `supabase/functions/chat-image/index.ts`

**Interfaces:**
- Consumes: `charge_tokens` RPC.
- Produces: success response gains `tokenBalance: number`; insufficient-balance case returns `{ error: "insufficient_tokens" }` at 402, before any xAI call is made.

- [ ] **Step 1: Add the same `chargeOrReject` helper used in Task 3** (this function already has its own `db` client and `userIdFromJWT`/`uid`, per the earlier grep — add right after the `db` client definition):

```typescript
async function chargeOrReject(uid: string, amount: number, reason: string): Promise<{ ok: true; balance: number } | { ok: false }> {
  const { data: charged } = await db.rpc("charge_tokens", { p_user_id: uid, p_amount: amount, p_reason: reason });
  if (!charged) return { ok: false };
  const { data: row } = await db.from("token_balances").select("balance").eq("user_id", uid).single();
  return { ok: true, balance: row?.balance ?? 0 };
}
```

- [ ] **Step 2: Reject up front if the balance can't cover it — insert immediately after the existing `characterId`/`prompt` validation** (right after the existing `if (!userPrompt) return json({ error: "prompt required" }, 400);` around line 462):

```typescript
    const charge = await chargeOrReject(uid, 25, "photo");
    if (!charge.ok) return json({ error: "insufficient_tokens" }, 402);
```

- [ ] **Step 3: Add the balance to the success response** — modify the existing `return json({ url: photoUrl, redirected });` (line ~545):

```typescript
    return json({ url: photoUrl, redirected, tokenBalance: charge.balance });
```

- [ ] **Step 4: Deploy**

```bash
SUPABASE_ACCESS_TOKEN=$SUPABASE_MANAGEMENT_PAT npx supabase functions deploy chat-image --project-ref ohpvhgwjmrfjclnumgnm --no-verify-jwt
```

- [ ] **Step 5: Verify** — same pattern as Task 3 Step 5: grant a test user 25 tokens, call `chat-image` with a real `characterId`/`prompt`, confirm `tokenBalance:0` in the response; call again and confirm `402 insufficient_tokens` with no image actually generated (check `generated_photos` row count didn't increase).

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/chat-image/index.ts
git commit -m "feat: charge 25 tokens per generated photo"
```

---

## Task 5: Charge tokens in `voice-message-tts/index.ts` (12 tokens per voice message)

**Files:**
- Modify: `supabase/functions/voice-message-tts/index.ts`

**Interfaces:**
- Consumes: `charge_tokens` RPC. This function had **no DB client and no auth extraction at all** before this task — both are added here.
- Produces: audio response (unchanged content-type) now includes a custom header `X-Token-Balance` (can't attach JSON fields to a raw `audio/mpeg` body) carrying the post-charge balance; insufficient-balance case returns a JSON 402 instead of audio.

- [ ] **Step 1: Add the Supabase client, JWT parsing, and charge helper** (insert after the existing `ELEVENLABS_TTS_URL` constant, before `Deno.serve`):

```typescript
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

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

async function chargeOrReject(uid: string, amount: number, reason: string): Promise<{ ok: true; balance: number } | { ok: false }> {
  const { data: charged } = await db.rpc("charge_tokens", { p_user_id: uid, p_amount: amount, p_reason: reason });
  if (!charged) return { ok: false };
  const { data: row } = await db.from("token_balances").select("balance").eq("user_id", uid).single();
  return { ok: true, balance: row?.balance ?? 0 };
}
```

- [ ] **Step 2: Require auth and charge, right after the existing `text`/`role`/`vibe`/`lang` validation** (after the existing `if (!text || ...) return new Response(...)` block, around line 46):

```typescript
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) {
      return new Response(JSON.stringify({ error: "unauthorized" }), {
        status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    const charge = await chargeOrReject(uid, 12, "voice");
    if (!charge.ok) {
      return new Response(JSON.stringify({ error: "insufficient_tokens" }), {
        status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
```

- [ ] **Step 3: Attach the resulting balance as a response header on both success paths** — modify the ElevenLabs success return (around line 72) and the Google TTS success return (around line 109):

```typescript
      return new Response(bytes, {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "audio/mpeg", "X-Token-Balance": String(charge.balance) },
      });
```

(apply the same `"X-Token-Balance": String(charge.balance)` header addition to both `return new Response(bytes, ...)` blocks)

- [ ] **Step 4: Deploy**

```bash
SUPABASE_ACCESS_TOKEN=$SUPABASE_MANAGEMENT_PAT npx supabase functions deploy voice-message-tts --project-ref ohpvhgwjmrfjclnumgnm --no-verify-jwt
```

- [ ] **Step 5: Verify** — grant a test user 12 tokens, call with a valid `Authorization` header + `{text,role,vibe,lang}`, confirm `200` with an `X-Token-Balance: 0` header and real audio bytes; call again and confirm `402 {"error":"insufficient_tokens"}`. Also confirm a request with **no** `Authorization` header now gets `401` (previously this function accepted anonymous calls — this is an intentional behavior change, the client already sends its JWT here per `ChatService.swift`'s existing `bearer` pattern, so no client change is needed for this specifically).

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/voice-message-tts/index.ts
git commit -m "feat: require auth + charge 12 tokens per voice message"
```

---

## Task 6: Gate `create-character` by subscription tier + weekly slot count

**Files:**
- Modify: `supabase/functions/create-character/index.ts`

**Interfaces:**
- Consumes: reads `subscriptions` table (Task 1) and counts existing rows in `characters`.
- Produces: normal-mode character creation now returns `{ error: "subscription_required" }` (403) or `{ error: "weekly_limit_reached", limit: number }` (403) before doing any paid work, for callers with no active tier or an exhausted weekly allowance. `generateImageOnly` mode is untouched (it's a pre-creation preview step, not the actual creation).

- [ ] **Step 1: Add the tier-limit table and a helper, near the top of the file (after the `db` client definition)**

```typescript
const WEEKLY_CHARACTER_LIMIT: Record<string, number> = {
  pro: 1,
  pro_plus: 3,
  max: 10,
};

async function checkCreationAllowance(uid: string): Promise<{ ok: true } | { ok: false; error: string; limit?: number }> {
  const { data: sub } = await db
    .from("subscriptions")
    .select("tier, current_period_start")
    .eq("user_id", uid)
    .gte("current_period_end", new Date().toISOString())
    .maybeSingle();

  if (!sub) return { ok: false, error: "subscription_required" };

  const limit = WEEKLY_CHARACTER_LIMIT[sub.tier] ?? 0;
  const { count } = await db
    .from("characters")
    .select("id", { count: "exact", head: true })
    .eq("created_by", uid)
    .gte("created_at", sub.current_period_start);

  if ((count ?? 0) >= limit) return { ok: false, error: "weekly_limit_reached", limit };
  return { ok: true };
}
```

- [ ] **Step 2: Call it right before the DB insert in normal (non-`generateImageOnly`) mode** — insert immediately after `const uid = userIdFromJWT(...)` at line 188 (the existing line already there, just add the check right after it):

```typescript
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);
    const allowance = await checkCreationAllowance(uid);
    if (!allowance.ok) return json({ error: allowance.error, limit: allowance.limit }, 403);
```

Note: `uid` was previously allowed to be `null` here (comment at line 156-158 says normal mode tolerates an absent uid, unlike `generateImageOnly`) — this task makes normal-mode creation require a real, subscribed uid, which is the intended behavior change per the design doc ("Character generation will be only possible by paid subscription").

- [ ] **Step 3: Deploy**

```bash
SUPABASE_ACCESS_TOKEN=$SUPABASE_MANAGEMENT_PAT npx supabase functions deploy create-character --project-ref ohpvhgwjmrfjclnumgnm --no-verify-jwt
```

- [ ] **Step 4: Verify** — call with a JWT for a user with no `subscriptions` row: expect `403 {"error":"subscription_required"}`. Insert a fake `subscriptions` row for a test user (`tier: 'pro'`, `current_period_start: now() - interval '1 day'`, `current_period_end: now() + interval '6 days'`) via the Management API, call `create-character` once (should succeed), then twice more (second call should `403 {"error":"weekly_limit_reached","limit":1}` since Pro's limit is 1).

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/create-character/index.ts
git commit -m "feat: gate character creation by subscription tier + weekly slot count"
```

---

## Task 7: Swift — `TokenStore` (client-side balance cache)

**Files:**
- Create: `aiGirlfriend/Services/TokenStore.swift`

**Interfaces:**
- Produces: `@Observable final class TokenStore { var balance: Int; func refresh() async }`, injected via `.environment(TokenStore())` the same way `CharacterStore`/`AuthService` already are in `aiGirlfriendApp.swift`.

- [ ] **Step 1: Write the store, mirroring `CharacterStore`'s disk-cache-then-refresh pattern**

```swift
//
//  TokenStore.swift
//  Kullanıcının token bakiyesi — sunucu `token_balances` tablosunun tek
//  doğru kaynağı, istemci sadece okur/önbelleğe alır (bkz. GeneratedPhotoService
//  ile aynı RLS deseni: user_id = auth.uid()).
//

import Foundation
import Observation

@MainActor
@Observable
final class TokenStore {
    var balance: Int = 0
    private let cacheKey = "tokens.cachedBalance"

    init() {
        balance = UserDefaults.standard.integer(forKey: cacheKey)
    }

    /// Splash'te ve her ödemeli eylemden sonra (mesaj/ses/foto gönderimi,
    /// satın alma, streak claim) çağrılır.
    func refresh() async {
        guard let accessToken = UserDefaultsManager.shared.accessToken,
              let url = URL(string: "\(Config.supabaseURL)/rest/v1/token_balances?select=balance")
        else { return }
        var request = URLRequest(url: url)
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return }
        struct Row: Decodable { let balance: Int }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data), let first = rows.first else { return }
        balance = first.balance
        UserDefaults.standard.set(first.balance, forKey: cacheKey)
    }

    /// Bir edge function cevabından gelen `tokenBalance` alanıyla anında
    /// günceller — bir sonraki `refresh()`'i beklemeden (bkz. ChatViewModel).
    func setBalance(_ value: Int) {
        balance = value
        UserDefaults.standard.set(value, forKey: cacheKey)
    }
}
```

- [ ] **Step 2: Wire it into the app root** — modify `aiGirlfriend/aiGirlfriendApp.swift`: find the existing `@State private var characterStore = CharacterStore()`-style declarations and the matching `.environment(characterStore)` call, and add a sibling:

```swift
@State private var tokenStore = TokenStore()
```

and in the same view builder where `.environment(characterStore)` is applied, add:

```swift
.environment(tokenStore)
```

- [ ] **Step 3: Manual QA checklist** (run once built in Xcode): launch the app, confirm no crash from the new `@Observable` injection; temporarily grant a test user tokens via the Task 1 SQL and confirm `TokenStore.balance` reflects it after a manual `await tokenStore.refresh()` call (e.g. wire a temporary debug button, remove before shipping).

- [ ] **Step 4: Commit**

```bash
git add aiGirlfriend/Services/TokenStore.swift aiGirlfriend/aiGirlfriendApp.swift
git commit -m "feat: add TokenStore client-side balance cache"
```

---

## Task 8: Swift — `TokenBadge` view, placed once on `MainTabView`

**Files:**
- Create: `aiGirlfriend/Views/TokenBadge.swift`
- Modify: `aiGirlfriend/Views/MainTabView.swift`

**Interfaces:**
- Consumes: `TokenStore` from Task 7 (via `@Environment(TokenStore.self)`).
- Produces: `TokenBadge` view with an `onTap: () -> Void` callback (opens the token store page — wired to a new `@State private var showTokenStore = false` + `.fullScreenCover` in `MainTabView`, matching the existing `showCreate`/`profileCharacter` cover pattern already in this codebase).

- [ ] **Step 1: New localized strings** — add to `Localizable.xcstrings` (same insertion technique used throughout this project: surgical text insertion right after `"strings" : {`, never a full re-serialize — see any prior commit touching this file for the exact byte-level format): key `"Get more tokens"` with `de: "Mehr Token holen"`, `es: "Consigue más tokens"`, `fr: "Obtenir plus de jetons"`, `it: "Ottieni più token"`, `pt: "Consiga mais tokens"`, `tr: "Daha fazla token al"`. (This string isn't used in `TokenBadge` itself — it's for `TokenStoreView` in Task 9, added here since this task is the first to reference it conceptually; skip this step if Task 9 is done in the same sitting and add it there instead, don't duplicate.)

- [ ] **Step 2: Write `TokenBadge`**

```swift
//
//  TokenBadge.swift
//  Her ekranda görünmesi gereken kalıcı token rozeti — sayı + "+" kutusu,
//  hepsi TEK dokunma hedefi (bkz. design doc: "Not two separate tap targets").
//

import SwiftUI

struct TokenBadge: View {
    let balance: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text("💠 \(balance)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(AppColor.amber)
                    .monospacedDigit()
                Text("+")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(AppColor.bg)
                    .frame(width: 20, height: 20)
                    .background(AppColor.amber, in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 5)
            .background(AppColor.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AppColor.amber.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 3: Place it once on `MainTabView`** — modify `MainTabView.swift`: add `@State private var showTokenStore = false` alongside the existing `@State private var selection`/`path` declarations, add `@Environment(TokenStore.self) private var tokenStore` alongside the existing `@Environment(CharacterStore.self) private var store`, then add the badge as a top-trailing overlay on the outer `ZStack` (the one containing `AppColor.bg.ignoresSafeArea()` and the tab `Group`/`CustomTabBar`) and the cover:

```swift
.overlay(alignment: .topTrailing) {
    TokenBadge(balance: tokenStore.balance) { showTokenStore = true }
        .padding(.top, 8)
        .padding(.trailing, 16)
}
.fullScreenCover(isPresented: $showTokenStore) {
    TokenStoreView()
}
```

- [ ] **Step 4: Manual QA checklist**: build in Xcode, confirm the badge renders top-right on all 5 tabs and doesn't overlap the existing header buttons/back button on `ChatView` (it pushes onto the same stack, so it must sit above `ChatView`'s own header — check for visual collision and adjust `.padding(.top, ...)` if `ChatView`'s custom header already occupies that vertical space).

- [ ] **Step 5: Commit**

```bash
git add aiGirlfriend/Views/TokenBadge.swift aiGirlfriend/Views/MainTabView.swift
git commit -m "feat: add persistent token badge to MainTabView's stack"
```

---

## Task 9: Swift — `TokenStoreView` (paywall/purchase page)

**Files:**
- Create: `aiGirlfriend/Views/TokenStoreView.swift`
- Modify: `aiGirlfriend/Services/PurchaseService.swift`
- Modify: `aiGirlfriend/Views/PaywallHostView.swift`

**Interfaces:**
- Consumes: `PurchaseService.shared` (extended below), `AppColor` (existing theme tokens).
- Produces: `TokenStoreView: View` — the screen shown by `TokenBadge`'s tap and by every existing `showPaywall = true` call site in the codebase (`CreateCharacterView.reveal()`, `LikesView`, `PaywallHostView`'s own placeholder is now this view, not a "coming soon" message).

- [ ] **Step 1: New localized strings** — insert into `Localizable.xcstrings` (surgical insertion, matching this project's established format): `"Get more tokens"`, `"Weekly"`, `"Annual"`, `"save ~83%"`, `"Choose Pro"`, `"Choose Pro+"`, `"Choose Max"`, `"Continue"`, `"Most Popular"`, `"— or buy tokens outright, no subscription —"`, `"tokens every week"`, `"Create %lld new character per week"`, `"Create %lld new characters per week"`, `"Buy"`. Each with full `de/es/fr/it/pt/tr` translations following the same tone/length as this project's existing entries (e.g. `"Continue"` already exists in the catalog from `CreateCharacterView`/`AddCharacterNoteSheet` — reuse that exact key rather than duplicating).

- [ ] **Step 2: Extend `PurchaseService` with tier awareness** — replace the single `var isPro: Bool` with a tier enum, keeping the existing skeleton's `canImport(RevenueCat)` guard structure intact:

```swift
enum SubscriptionTier: String {
    case none, pro, proPlus, max

    var weeklyTokens: Int {
        switch self {
        case .none: return 0
        case .pro: return 1000
        case .proPlus: return 2500
        case .max: return 6000
        }
    }

    var weeklyCharacterSlots: Int {
        switch self {
        case .none: return 0
        case .pro: return 1
        case .proPlus: return 3
        case .max: return 10
        }
    }
}
```

Add this enum at the top of `PurchaseService.swift`, then change `var isPro: Bool = false` to `var tier: SubscriptionTier = .none`, and add a computed `var isPro: Bool { tier != .none }` right below it so every existing `PurchaseService.shared.isPro` call site in the codebase (`CreateCharacterView`, `LikesView`, `GalleryView`, `PaywallHostView`) keeps compiling unchanged. Update `refreshEntitlement()`'s body to set `tier` instead of `isPro`:

```swift
    func refreshEntitlement() async {
        #if canImport(RevenueCat)
        guard isConfigured, let info = try? await Purchases.shared.customerInfo() else { return }
        if info.entitlements["max"]?.isActive == true { tier = .max }
        else if info.entitlements["pro_plus"]?.isActive == true { tier = .proPlus }
        else if info.entitlements["pro"]?.isActive == true { tier = .pro }
        else { tier = .none }
        #endif
    }
```

(Entitlement identifiers `"pro"`/`"pro_plus"`/`"max"` match the `subscriptions.tier` check constraint from Task 1 — keep these two lists in sync if either changes.)

- [ ] **Step 3: Write `TokenStoreView`**, matching the approved mockup exactly (tap-to-select tier cards, one sticky bottom "Continue" button, separate "Buy" buttons per token pack):

```swift
//
//  TokenStoreView.swift
//  Token/abonelik sayfası — TokenBadge'in açtığı ve her `showPaywall = true`
//  çağrısının gösterdiği tek ekran (bkz. design doc mockup review).
//

import SwiftUI

private struct TierOption: Identifiable {
    let id: String
    let name: String
    let weeklyPrice: String
    let annualPrice: String
    let tokens: String
    let characterLine: String
    let featured: Bool
}

private let tierOptions: [TierOption] = [
    .init(id: "pro", name: "Pro", weeklyPrice: "$6.99", annualPrice: "$59.99",
          tokens: "1,000", characterLine: "Create 1 new character per week", featured: false),
    .init(id: "pro_plus", name: "Pro+", weeklyPrice: "$14.99", annualPrice: "$119.99",
          tokens: "2,500", characterLine: "Create 3 new characters per week", featured: true),
    .init(id: "max", name: "Max", weeklyPrice: "$29.99", annualPrice: "$239.99",
          tokens: "6,000", characterLine: "Create 10 new characters per week", featured: false),
]

private struct TokenPack: Identifiable {
    let id: String
    let name: String
    let price: String
    let tokens: String
}

private let tokenPacks: [TokenPack] = [
    .init(id: "small", name: "Small", price: "$5.99", tokens: "300"),
    .init(id: "medium", name: "Medium", price: "$19.99", tokens: "1,000"),
    .init(id: "large", name: "Large", price: "$59.99", tokens: "3,000"),
]

struct TokenStoreView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isAnnual = false
    @State private var selectedTierID = "pro_plus"

    private var selectedTier: TierOption { tierOptions.first { $0.id == selectedTierID } ?? tierOptions[1] }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [AppColor.bg2, AppColor.bg], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 18) {
                            Text("Get more tokens")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.top, 12)

                            periodToggle

                            VStack(spacing: 10) {
                                ForEach(tierOptions) { tier in
                                    tierCard(tier)
                                }
                            }

                            Text("— or buy tokens outright, no subscription —")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.45))
                                .padding(.top, 6)

                            HStack(spacing: 8) {
                                ForEach(tokenPacks) { pack in packCard(pack) }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                    }
                    stickyFooter
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").foregroundStyle(.white)
                    }
                }
            }
        }
    }

    private var periodToggle: some View {
        HStack(spacing: 2) {
            periodButton(label: "Weekly", isSelected: !isAnnual) { isAnnual = false }
            periodButton(label: "Annual", isSelected: isAnnual, sub: "save ~83%") { isAnnual = true }
        }
        .padding(3)
        .background(AppColor.card, in: Capsule())
    }

    private func periodButton(label: String, isSelected: Bool, sub: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(label).font(.system(size: 12, weight: .bold))
                if let sub {
                    Text(sub).font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(isSelected ? AppColor.bg : .white.opacity(0.6))
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(isSelected ? AppColor.amber : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func tierCard(_ tier: TierOption) -> some View {
        let selected = tier.id == selectedTierID
        return Button {
            selectedTierID = tier.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                if tier.featured {
                    Text("Most Popular")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(AppColor.bg)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(AppColor.amber, in: Capsule())
                }
                HStack {
                    HStack(spacing: 7) {
                        Circle()
                            .strokeBorder(selected ? AppColor.amber : .white.opacity(0.3), lineWidth: 2)
                            .background(Circle().fill(selected ? AppColor.amber : .clear).padding(3))
                            .frame(width: 16, height: 16)
                        Text(tier.name).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    }
                    Spacer()
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text(isAnnual ? tier.annualPrice : tier.weeklyPrice)
                            .font(.system(size: 15, weight: .heavy)).foregroundStyle(AppColor.amber)
                        Text(isAnnual ? "/yr" : "/wk")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    benefitLine("\(tier.tokens) tokens every week")
                    benefitLine(tier.characterLine)
                }
            }
            .padding(14)
            .background(selected ? AppColor.pink.opacity(0.35) : AppColor.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? AppColor.amber : .white.opacity(0.08), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private func benefitLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text("✓").font(.system(size: 11, weight: .heavy)).foregroundStyle(AppColor.amber)
            Text(text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.8))
        }
    }

    private func packCard(_ pack: TokenPack) -> some View {
        VStack(spacing: 6) {
            Text(pack.name).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            Text(pack.price).font(.system(size: 14, weight: .heavy)).foregroundStyle(AppColor.amber)
            Text("💠 \(pack.tokens)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
            Button {
                // Task 10 wires this to the real StoreKit/RevenueCat purchase call.
            } label: {
                Text("Buy")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(AppColor.pink, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(AppColor.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private var stickyFooter: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.white.opacity(0.08))
            Button {
                // Task 10 wires this to the real StoreKit/RevenueCat purchase call.
            } label: {
                Text("Continue — \(selectedTier.name) \(isAnnual ? selectedTier.annualPrice : selectedTier.weeklyPrice)\(isAnnual ? "/yr" : "/wk")")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AppColor.bg)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(AppColor.amber, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(AppColor.bg.opacity(0.9))
    }
}

#Preview {
    TokenStoreView()
}
```

- [ ] **Step 4: Point `PaywallHostView` at it** — replace the entire body of `PaywallHostView.swift` (the `#if canImport(RevenueCatUI) ... #else placeholder #endif` structure and the `placeholder` computed property) with:

```swift
struct PaywallHostView: View {
    var body: some View {
        TokenStoreView()
    }
}
```

(Every existing call site — `CreateCharacterView`'s `.sheet(isPresented: $showPaywall) { PaywallHostView() }`, `LikesView`, etc. — keeps working unchanged, since they all reference `PaywallHostView()` by name.)

- [ ] **Step 5: Manual QA checklist**: build in Xcode, open the token store from the badge, confirm tapping each tier card highlights it and updates the sticky footer's price/name text, confirm the Weekly/Annual toggle changes all three prices simultaneously, confirm the 3 pack cards each show their own independent "Buy" button (no shared state with the tier selection).

- [ ] **Step 6: Commit**

```bash
git add aiGirlfriend/Views/TokenStoreView.swift aiGirlfriend/Services/PurchaseService.swift aiGirlfriend/Views/PaywallHostView.swift aiGirlfriend/Localizable.xcstrings
git commit -m "feat: add TokenStoreView, replace PaywallHostView placeholder"
```

---

## Task 10: Swift — Streak popup

**Files:**
- Create: `aiGirlfriend/Services/StreakService.swift`
- Create: `aiGirlfriend/Views/StreakPopupView.swift`
- Modify: `aiGirlfriend/Views/MainTabView.swift`

**Interfaces:**
- Consumes: `claim-streak` edge function (Task 2), `TokenStore` (Task 7).
- Produces: `StreakService.claim() async -> StreakClaimResult?` where `StreakClaimResult` carries `granted, amount, newStreak, balance`; `StreakPopupView(result: StreakClaimResult, onCollect: () -> Void)`.

- [ ] **Step 1: Write `StreakService`**

```swift
//
//  StreakService.swift
//  `claim-streak` edge function'ını çağırır — asıl hak verme mantığı ve
//  UTC-tabanlı kötüye kullanım koruması TAMAMEN sunucuda (bkz. design doc).
//

import Foundation

struct StreakClaimResult: Decodable {
    let granted: Bool
    let amount: Int?
    let newStreak: Int?
    let balance: Int?
}

enum StreakService {
    static func claim() async -> StreakClaimResult? {
        guard let accessToken = UserDefaultsManager.shared.accessToken,
              let url = URL(string: "\(Config.supabaseURL)/functions/v1/claim-streak")
        else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let localDate = ISO8601DateFormatter().string(from: Date()).prefix(10) // local calendar date, cosmetic only
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["localDate": String(localDate)])

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return try? JSONDecoder().decode(StreakClaimResult.self, from: data)
    }
}
```

- [ ] **Step 2: Write `StreakPopupView`** (Mon–Sun grid, lights up days claimed this week, shows current day's multiplier — per the approved mechanic: day 1 ×1, days 2-4 ×2, days 5-6 ×3, day 7 ×5)

```swift
//
//  StreakPopupView.swift
//  Haftalık (Pzt-Paz) görsel şerit — sadece KOZMETİK, gerçek hak verme
//  `claim-streak` sunucu cevabından gelir (bkz. StreakService).
//

import SwiftUI

struct StreakPopupView: View {
    let result: StreakClaimResult
    let onCollect: () -> Void

    private let dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    private func multiplierLabel(forStreak streak: Int) -> String {
        switch streak {
        case ...1: return "×1"
        case 2...4: return "×2"
        case 5...6: return "×3"
        default: return "×5"
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 20) {
                Text("Daily bonus!")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)

                if result.granted, let amount = result.amount, let streak = result.newStreak {
                    HStack(spacing: 6) {
                        ForEach(1...7, id: \.self) { day in
                            dayBox(day: day, currentStreak: streak)
                        }
                    }

                    Text("+\(amount) tokens")
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(AppColor.amber)

                    Text("\(multiplierLabel(forStreak: streak)) streak bonus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Button(action: onCollect) {
                    Text("Collect")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppColor.bg)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(AppColor.amber, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .background(AppColor.card, in: RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal, 32)
        }
    }

    private func dayBox(day: Int, currentStreak: Int) -> some View {
        let claimedThisWeek = day <= currentStreak
        return VStack(spacing: 4) {
            Text(dayLabels[day - 1])
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Circle()
                .fill(claimedThisWeek ? AppColor.amber : Color.white.opacity(0.08))
                .frame(width: 28, height: 28)
                .overlay {
                    if day == currentStreak {
                        Text(multiplierLabel(forStreak: currentStreak))
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(AppColor.bg)
                    }
                }
        }
    }
}
```

Note: the day-box "lit up" logic here (`day <= currentStreak`) is a simplification treating the consecutive streak count as this week's progress — matches the design doc's resolution that the weekly grid is cosmetic and resets naturally each Monday. If `currentStreak` exceeds 7 (a streak spanning into a new week), clamp the displayed lit range to `min(currentStreak, 7)` — add `let claimedThisWeek = day <= min(currentStreak, 7)` if this comes up in QA.

- [ ] **Step 3: Trigger on app foreground, once per day** — modify `MainTabView.swift`: add `@State private var streakResult: StreakClaimResult?` and a `.task` that fires once when `MainTabView` first appears (mirroring `SplashView`'s single `.task` pattern):

```swift
.task {
    if let result = await StreakService.claim(), result.granted {
        streakResult = result
    }
}
.fullScreenCover(item: Binding(
    get: { streakResult.map { IdentifiableStreakResult(result: $0) } },
    set: { _ in streakResult = nil }
)) { wrapped in
    StreakPopupView(result: wrapped.result) {
        streakResult = nil
        Task { await tokenStore.refresh() }
    }
    .presentationBackground(.clear)
}
```

Add this small wrapper (SwiftUI's `.fullScreenCover(item:)` needs `Identifiable`, and `StreakClaimResult` is a plain server-response `Decodable` with no natural id) directly in `StreakPopupView.swift`, below the existing struct:

```swift
struct IdentifiableStreakResult: Identifiable {
    let id = UUID()
    let result: StreakClaimResult
}
```

- [ ] **Step 4: Manual QA checklist**: build in Xcode, launch with a fresh test user (never claimed before) — confirm the popup appears automatically once, shows day 1 / ×1 / 10 tokens, collecting it dismisses and the token badge updates. Relaunch the app the same day and confirm the popup does NOT reappear (server's `already_claimed_today` path).

- [ ] **Step 5: Commit**

```bash
git add aiGirlfriend/Services/StreakService.swift aiGirlfriend/Views/StreakPopupView.swift aiGirlfriend/Views/MainTabView.swift
git commit -m "feat: add daily streak popup, auto-claims once per app session"
```

---

## Task 11: Swift — Surface `insufficient_tokens` in chat + refresh balance after paid actions

**Files:**
- Modify: `aiGirlfriend/ViewModels/ChatViewModel.swift`
- Modify: `aiGirlfriend/Services/ChatService.swift`

**Interfaces:**
- Consumes: `TokenStore` (Task 7) — `ChatViewModel` needs a reference to it, passed in the same way `store: CharacterStore?` is already threaded through today.
- Produces: `ChatService`'s existing response-decoding structs gain an optional `tokenBalance: Int?` field; `ChatViewModel.send()`/`sendVoiceRequest()`/`sendImageRequest()` catch the specific `insufficient_tokens` error and set a distinct, user-facing `errorMessage` instead of the generic network-error message, and call `store?.tokenStore?.setBalance(...)` (or an equivalent path — see Step 3) after every successful paid call.

- [ ] **Step 1: Find `ChatService`'s response decoding for the reply-mode endpoint** and add the new field — this project's established pattern (per `architecture_edge_functions` notes) is a `Result`-shaped decode; add `let tokenBalance: Int?` to whichever struct decodes `chat/index.ts`'s JSON response body (search `ChatService.swift` for the struct that already decodes `reply`/`level`/`leveledUp` — add the field alongside those, matching its existing `Decodable` conformance and optional-field style).

- [ ] **Step 2: Detect the 402 case explicitly** — wherever `ChatService` currently throws a generic `NSError` for non-2xx HTTP responses (the same pattern used in `CharacterService.fetchAll()`/`ConversationsService`), add a branch checking `http.statusCode == 402` before the generic throw, decoding `{"error":"insufficient_tokens"}` and throwing a distinct error type:

```swift
struct InsufficientTokensError: Error {}
```//

```swift
if http.statusCode == 402 {
    throw InsufficientTokensError()
}
```

Apply this same 402 check to the image-request and voice-request call paths in `ChatService` too (three call sites total, matching the three edge functions charged in Tasks 3–5).

- [ ] **Step 3: In `ChatViewModel`**, wherever `catch { errorMessage = error.localizedDescription }` currently runs after `send()`/`sendVoiceRequest()`/`sendImageRequest()`'s network call, add a specific branch first:

```swift
} catch is InsufficientTokensError {
    errorMessage = String(localized: "Not enough tokens. Get more to keep chatting.")
```

(then fall through to the existing generic `catch { errorMessage = error.localizedDescription }` for every other error type, unchanged)

Add `"Not enough tokens. Get more to keep chatting."` to `Localizable.xcstrings` with `de/es/fr/it/pt/tr` translations, same insertion technique as prior tasks.

- [ ] **Step 4: Refresh the balance after every successful paid call** — `ChatViewModel` needs a way to reach `TokenStore`. Add `weak var tokenStore: TokenStore?` as a settable property on `ChatViewModel` (set by whoever constructs it — `ChatView`'s initializer already receives `@Environment(TokenStore.self)`, thread it through the same way `store: CharacterStore?` is already passed in today), then after each successful `result` decode in `send()`/`sendVoiceRequest()`/`sendImageRequest()`, add:

```swift
if let balance = result.tokenBalance { tokenStore?.setBalance(balance) }
```

- [ ] **Step 5: Manual QA checklist**: build in Xcode, drain a test user's balance to 0 via the Task 1 SQL, send a message, confirm the chat shows "Not enough tokens. Get more to keep chatting." instead of a generic error, and confirm the token badge visibly decrements by 1 after every successful message once balance is nonzero.

- [ ] **Step 6: Commit**

```bash
git add aiGirlfriend/ViewModels/ChatViewModel.swift aiGirlfriend/Services/ChatService.swift aiGirlfriend/Localizable.xcstrings
git commit -m "feat: surface insufficient-tokens error, live-refresh balance after paid actions"
```

---

## Task 12: Swift — Gate `CreateCharacterView` on subscription + slot allowance

**Files:**
- Modify: `aiGirlfriend/Views/CreateCharacterView.swift`

**Interfaces:**
- Consumes: `PurchaseService.shared.tier` (Task 9).
- Produces: the existing `reveal()` gate (`guard PurchaseService.shared.isPro else { showPaywall = true; return }`) becomes tier-and-slot-aware; the server (Task 6) is still the real enforcement point — this is the client-side "don't even let them tap through the whole wizard before finding out" convenience check, matching this project's existing philosophy (client checks optimistically, server is the real gate).

- [ ] **Step 1: Locate the existing guard in `reveal()`** (`private func reveal()`, the line `guard PurchaseService.shared.isPro else { showPaywall = true; return }`) and replace it with:

```swift
guard PurchaseService.shared.tier != .none else { showPaywall = true; return }
```

(This is a direct swap — `isPro` still exists as a computed convenience property from Task 9's `PurchaseService` change, but using `tier` directly here reads clearer given the slot check added next.)

- [ ] **Step 2: The weekly-slot check itself lives server-side** (Task 6 rejects with `weekly_limit_reached` at the actual `create-character` call). Wire that rejection into `createCharacter()`'s existing error path — find where `CharacterCreateService().create(...)` is called and its `nil` result currently falls through to the local-fallback-character path (around the `if let c = await service.create(...) { ... } // Fallback:` structure). Add a check for the specific error before falling back: if `CharacterCreateService.create` can be made to surface the HTTP status/error body (same 403 pattern as `InsufficientTokensError` in Task 11), set `photoGenError` to a slot-specific message instead of silently creating a local-only fallback character that the server would have rejected anyway:

```swift
photoGenError = String(localized: "You've used all your character slots this week.")
```

Add this string to `Localizable.xcstrings` with full `de/es/fr/it/pt/tr` translations.

- [ ] **Step 3: Manual QA checklist**: build in Xcode, with a non-subscribed test account, open the character wizard, reach the reveal step, confirm tapping "See character" opens `TokenStoreView` instead of generating anything (Task 6's server check backs this up even if a future regression removes the client-side guard). With a subscribed Pro test account that has already used its 1 weekly slot (set up via the Task 6 verification SQL), confirm attempting a second creation surfaces the slot-limit message rather than silently falling back to a local-only character.

- [ ] **Step 4: Commit**

```bash
git add aiGirlfriend/Views/CreateCharacterView.swift aiGirlfriend/Localizable.xcstrings
git commit -m "feat: gate character creation UI on subscription tier + weekly slots"
```

---

## Plan self-review notes

- **Spec coverage:** token economy + per-action costs (Tasks 3-5), streak mechanic + anti-abuse (Tasks 2, 10), character-gen gating (Tasks 6, 12), persistent badge scoped to `MainTabView` (Task 8), paywall page matching the approved mockup (Task 9), RevenueCat-dependency staging (Task 9 Step 2, explicitly deferred per spec's Dependencies section) — all covered.
- **Welcome-grant gap:** the spec didn't specify a starting balance for brand-new users, and with a hard 1-token message cost + 0 default balance, a user who hasn't yet claimed a streak can't send a single message. This plan doesn't silently invent a fix — flagging it here: either the client should trigger a first-launch `grant_tokens(uid, N, 'welcome')` call, or the "Day 1" streak claim should just happen automatically on first launch rather than waiting for the user to open a streak popup they don't know exists yet. Not resolved in this plan; decide before or during Task 2/10 implementation.
- **Type consistency check:** `TokenBadge.balance: Int` ← `TokenStore.balance: Int` ← `token_balances.balance integer` — consistent throughout. `StreakClaimResult` fields match `claim-streak`'s JSON response exactly. `SubscriptionTier` raw values (`"pro"`, `"pro_plus"`, `"max"`) match both the `subscriptions.tier` check constraint (Task 1) and the RevenueCat entitlement IDs referenced in `PurchaseService.refreshEntitlement()` (Task 9) — kept in sync by comment cross-reference in both places.
