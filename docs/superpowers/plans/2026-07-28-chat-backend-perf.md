# Chat Backend Perf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut chat-reply latency by parallelizing independent DB round trips in `supabase/functions/chat/index.ts`, and eliminate the duplicated memories/behaviors-fetch code between the main reply path and the `photoDownloadReaction` branch — per `docs/superpowers/specs/2026-07-28-chat-backend-perf-design.md`.

**Architecture:** One new shared helper (`fetchDirectiveMemoriesBehaviors`) that fires the directive/memories/behaviors queries in parallel via `Promise.all`, plus two tiny formatter helpers (`memoriesBlock`, `behaviorsBlock`) that both call sites already build identically today. The character+conversation lookup at the top of the handler is separately parallelized. No new files, no schema changes, no client changes.

**Tech Stack:** Deno edge function (TypeScript), Supabase JS client. No local Deno CLI or test framework available (same constraint as the token-cost plan) — verification is manual diff review plus post-deploy smoke testing.

## Global Constraints

- Scope is `supabase/functions/chat/index.ts` only.
- No behavior change to what gets sent to the LLM or returned to the client — this is a pure latency/duplication refactor. In particular: the main reply path does NOT call `wrapDirective()` today (only the `photoDownloadReaction` branch does) — this asymmetry is existing behavior and must be preserved exactly, not "fixed," since changing it would alter the live prompt.
- The main reply path's memories/behaviors blocks are appended AFTER all the static rule blocks (deliberate prompt-cache ordering, per existing comment at the exHistory/memoryRows/behaviorRows append site) — the shared helper must not force a reordering of where those blocks land in `system`.
- No deployed-function deletions in this plan (spec explicitly defers that).

---

### Task 1: Add `fetchDirectiveMemoriesBehaviors` + block formatter helpers

**Files:**
- Modify: `supabase/functions/chat/index.ts:191` (insert immediately after the closing brace of `fetchDirective`, before the `wrapDirective` comment block)

**Interfaces:**
- Consumes: existing `fetchDirective(characterId: string, role: string, level: number): Promise<string>` (unchanged, from the token-cost plan).
- Produces:
  - `fetchDirectiveMemoriesBehaviors(characterId: string, role: string, level: number, conversationId: string): Promise<{ directive: string; memories: { content: string }[]; behaviors: { content: string }[] }>`
  - `memoriesBlock(memories: { content: string }[]): string`
  - `behaviorsBlock(behaviors: { content: string }[]): string`
  - These three are consumed by Task 2 and Task 3.

- [ ] **Step 1: Insert the helpers**

In `supabase/functions/chat/index.ts`, immediately after the closing `}` of `fetchDirective` (line 191) and before the `// Directive'i çıplak enjekte etmek...` comment, insert:

```ts

// Fetches the three pieces every reply-producing path needs (main reply +
// photoDownloadReaction) in parallel instead of sequentially — none of the
// three queries depend on each other's results. Callers keep their own
// assembly order/wrapping (main path uses the raw directive, reaction path
// wraps it via wrapDirective — that asymmetry is existing behavior, this
// helper only shares the FETCH, not the string-building).
async function fetchDirectiveMemoriesBehaviors(
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
    fetchDirective(characterId, role, level),
    db.from("memories").select("content").eq("conversation_id", conversationId)
      .order("created_at", { ascending: true }),
    db.from("conversation_behaviors").select("content").eq("conversation_id", conversationId)
      .order("created_at", { ascending: true }),
  ]);
  return {
    directive,
    memories: memoriesResult.data ?? [],
    behaviors: behaviorsResult.data ?? [],
  };
}

// Both the main reply path and photoDownloadReaction build these two blocks
// with byte-identical formatting — shared here instead of duplicated.
function memoriesBlock(memories: { content: string }[]): string {
  if (memories.length === 0) return "";
  return `\n\n[MEMORIES — facts to remember about the user/relationship]\n` +
    memories.map((m) => `- ${m.content}`).join("\n");
}
function behaviorsBlock(behaviors: { content: string }[]): string {
  if (behaviors.length === 0) return "";
  return `\n\n[BEHAVIOR PREFERENCES — how the user wants you to act]\n` +
    behaviors.map((b) => `- ${b.content}`).join("\n");
}
```

- [ ] **Step 2: Verify the diff**

Run: `git diff supabase/functions/chat/index.ts`
Expected: only the new block inserted, nothing else changed yet (Tasks 2/3 haven't wired it in).

- [ ] **Step 3: Commit**

```bash
git add supabase/functions/chat/index.ts
git commit -m "perf(chat): add shared parallel directive/memories/behaviors fetch helper"
```

---

### Task 2: Wire the helper into the main reply path

**Files:**
- Modify: `supabase/functions/chat/index.ts` (the `// === CEVAP MODU: sistem promptunu hazırla ===` block, currently starting around line 952, and the memories/behaviors append site currently around line 1006-1013)

**Interfaces:**
- Consumes: `fetchDirectiveMemoriesBehaviors`, `memoriesBlock`, `behaviorsBlock` from Task 1.
- Produces: nothing new for later tasks.

- [ ] **Step 1: Replace the sequential fetch block**

Find (currently around line 952-970):

```ts
    // === CEVAP MODU: sistem promptunu hazırla ===
    const currentLevel: number = convo.relationship_level ?? 1;
    let system = systemPrompt;
    const directive = await fetchDirective(characterId, personalityRole, currentLevel);
    system += `\n\n${directive}`;
    // Kullanıcının "Anı Ekle" / "Davranış Ekle" ile eklediği kalıcı notlar
    // (her rol için geçerli — ex'e özel değil). Fetch stays here; the actual
    // `system +=` append happens further down, deliberately after all the
    // static rule blocks — see the cache-ordering comment there.
    const { data: memoryRows } = await db
      .from("memories")
      .select("content")
      .eq("conversation_id", conversationId)
      .order("created_at", { ascending: true });
    const { data: behaviorRows } = await db
      .from("conversation_behaviors")
      .select("content")
      .eq("conversation_id", conversationId)
      .order("created_at", { ascending: true });
```

Replace with:

```ts
    // === CEVAP MODU: sistem promptunu hazırla ===
    const currentLevel: number = convo.relationship_level ?? 1;
    let system = systemPrompt;
    // Kullanıcının "Anı Ekle" / "Davranış Ekle" ile eklediği kalıcı notlar
    // (her rol için geçerli — ex'e özel değil). memoryRows/behaviorRows used
    // further down, deliberately after all the static rule blocks — see the
    // cache-ordering comment there.
    const { directive, memories: memoryRows, behaviors: behaviorRows } =
      await fetchDirectiveMemoriesBehaviors(characterId, personalityRole, currentLevel, conversationId);
    system += `\n\n${directive}`;
```

(The three queries — directive, memories, behaviors — now run in parallel instead of sequentially. `directive` is still appended raw/unwrapped immediately, exactly as before — no behavior change.)

- [ ] **Step 2: Replace the manual block-building with the shared formatters**

Find (currently around line 1006-1013):

```ts
    if (memoryRows && memoryRows.length > 0) {
      system += `\n\n[MEMORIES — facts to remember about the user/relationship]\n` +
        memoryRows.map((m) => `- ${m.content}`).join("\n");
    }
    if (behaviorRows && behaviorRows.length > 0) {
      system += `\n\n[BEHAVIOR PREFERENCES — how the user wants you to act]\n` +
        behaviorRows.map((b) => `- ${b.content}`).join("\n");
    }
```

Replace with:

```ts
    system += memoriesBlock(memoryRows);
    system += behaviorsBlock(behaviorRows);
```

- [ ] **Step 3: Verify the diff**

Run: `git diff supabase/functions/chat/index.ts`
Expected: the sequential-fetch block replaced with the parallel helper call, the manual `if`-blocks replaced with the two formatter calls. The position of `system += `\n\n${directive}`;` relative to the static rule blocks below it, and the position of the memories/behaviors appends relative to `exHistory`/summary, must be unchanged — only HOW the data is fetched/formatted changed, not WHERE it lands in `system`.

Run: `grep -n "fetchDirective(characterId, personalityRole, currentLevel)\|fetchDirectiveMemoriesBehaviors(characterId, personalityRole, currentLevel" supabase/functions/chat/index.ts`
Expected: the old direct `fetchDirective(...)` call at this site is gone, replaced by `fetchDirectiveMemoriesBehaviors(...)`.

- [ ] **Step 4: Commit**

```bash
git add supabase/functions/chat/index.ts
git commit -m "perf(chat): parallelize directive/memories/behaviors fetch in main reply path"
```

---

### Task 3: Wire the helper into `photoDownloadReaction`

**Files:**
- Modify: `supabase/functions/chat/index.ts` (the `photoDownloadReaction` branch, currently lines 881-938)

**Interfaces:**
- Consumes: `fetchDirectiveMemoriesBehaviors`, `memoriesBlock`, `behaviorsBlock` from Task 1.
- Produces: nothing new for later tasks.

- [ ] **Step 1: Replace the sequential fetch + manual block-building**

Find (currently around line 896-922):

```ts
      const reactionLevel: number = convo.relationship_level ?? 1;
      const reactionProgress: number = typeof convo.level_progress === "number" ? convo.level_progress : 0;
      const reactionDirective = await fetchDirective(characterId, personalityRole, reactionLevel);
      let reactionSystem = systemPrompt;
      reactionSystem += wrapDirective(reactionDirective, Math.round(reactionProgress * 100));
      if (exHistory) {
        reactionSystem += `\n\n[SHARED HISTORY — reference these memories naturally in conversation]\n${exHistory}`;
      }

      const { data: reactionMemoryRows } = await db
        .from("memories")
        .select("content")
        .eq("conversation_id", conversationId)
        .order("created_at", { ascending: true });
      const { data: reactionBehaviorRows } = await db
        .from("conversation_behaviors")
        .select("content")
        .eq("conversation_id", conversationId)
        .order("created_at", { ascending: true });
      if (reactionMemoryRows && reactionMemoryRows.length > 0) {
        reactionSystem += `\n\n[MEMORIES — facts to remember about the user/relationship]\n` +
          reactionMemoryRows.map((m) => `- ${m.content}`).join("\n");
      }
      if (reactionBehaviorRows && reactionBehaviorRows.length > 0) {
        reactionSystem += `\n\n[BEHAVIOR PREFERENCES — how the user wants you to act]\n` +
          reactionBehaviorRows.map((b) => `- ${b.content}`).join("\n");
      }
```

Replace with:

```ts
      const reactionLevel: number = convo.relationship_level ?? 1;
      const reactionProgress: number = typeof convo.level_progress === "number" ? convo.level_progress : 0;
      const { directive: reactionDirective, memories: reactionMemoryRows, behaviors: reactionBehaviorRows } =
        await fetchDirectiveMemoriesBehaviors(characterId, personalityRole, reactionLevel, conversationId);
      let reactionSystem = systemPrompt;
      reactionSystem += wrapDirective(reactionDirective, Math.round(reactionProgress * 100));
      if (exHistory) {
        reactionSystem += `\n\n[SHARED HISTORY — reference these memories naturally in conversation]\n${exHistory}`;
      }
      reactionSystem += memoriesBlock(reactionMemoryRows);
      reactionSystem += behaviorsBlock(reactionBehaviorRows);
```

(`wrapDirective` usage is preserved exactly — this branch still wraps, matching existing behavior. Only the fetch is now parallel and the block-building now uses the shared formatters.)

- [ ] **Step 2: Verify the diff**

Run: `git diff supabase/functions/chat/index.ts`
Expected: three sequential awaits (directive, memories, behaviors) replaced by one `fetchDirectiveMemoriesBehaviors` call; `wrapDirective(reactionDirective, ...)` call still present and unchanged; the `exHistory` append still happens between the directive-wrap and the memories block, matching the original order exactly.

- [ ] **Step 3: Commit**

```bash
git add supabase/functions/chat/index.ts
git commit -m "perf(chat): parallelize directive/memories/behaviors fetch in photoDownloadReaction"
```

---

### Task 4: Parallelize the character + conversation lookup

**Files:**
- Modify: `supabase/functions/chat/index.ts:683-704`

**Interfaces:**
- Consumes: nothing new.
- Produces: `character`, `charErr`, `convoRows`, `convo` — same names/types as before, consumed unchanged by every branch below this point in the handler.

- [ ] **Step 1: Replace the sequential fetches**

Find (currently lines 683-704):

```ts
    // Fetch character personality role and ex_history
    const { data: character, error: charErr } = await db
      .from("characters")
      .select("personality_role, ex_history, interests")
      .eq("id", characterId)
      .maybeSingle();
    if (charErr) console.error("char fetch err:", JSON.stringify(charErr));
    const personalityRole: string = character?.personality_role ?? "flirty";
    const interests: string[] = Array.isArray(character?.interests) ? character.interests : [];
    const exHistory: string | null = character?.ex_history ?? null;

    // 1) Konuşmayı bul ya da oluştur (kullanıcı + karakter). maybeSingle KULLANMA —
    // eski dupe'lar varsa hata verip convo=null oluyor ve HER mesajda YENİ bir
    // conversation ekleniyordu (dupe'lar böyle çoğalıyordu). En güncel olanı al.
    let { data: convoRows } = await db
      .from("conversations")
      .select("id, summary, summarized_count, xp, relationship_level, level_progress, schedule, woken_up_at, manual_sleep_at, ghosted_at, detected_language")
      .eq("user_id", uid)
      .eq("character_id", characterId)
      .order("updated_at", { ascending: false })
      .limit(1);
    let convo = convoRows?.[0];
```

Replace with:

```ts
    // Fetch character personality role/ex_history and the existing conversation
    // row in parallel — neither depends on the other's result, only on
    // uid/characterId which are already known at this point.
    // 1) Konuşmayı bul ya da oluştur (kullanıcı + karakter). maybeSingle KULLANMA —
    // eski dupe'lar varsa hata verip convo=null oluyor ve HER mesajda YENİ bir
    // conversation ekleniyordu (dupe'lar böyle çoğalıyordu). En güncel olanı al.
    const [{ data: character, error: charErr }, { data: convoRows }] = await Promise.all([
      db
        .from("characters")
        .select("personality_role, ex_history, interests")
        .eq("id", characterId)
        .maybeSingle(),
      db
        .from("conversations")
        .select("id, summary, summarized_count, xp, relationship_level, level_progress, schedule, woken_up_at, manual_sleep_at, ghosted_at, detected_language")
        .eq("user_id", uid)
        .eq("character_id", characterId)
        .order("updated_at", { ascending: false })
        .limit(1),
    ]);
    if (charErr) console.error("char fetch err:", JSON.stringify(charErr));
    const personalityRole: string = character?.personality_role ?? "flirty";
    const interests: string[] = Array.isArray(character?.interests) ? character.interests : [];
    const exHistory: string | null = character?.ex_history ?? null;
    let convo = convoRows?.[0];
```

Note: `convo` must stay `let` (it's reassigned later when a new conversation row is created), but `convoRows` no longer needs to be `let` since it's not reassigned anywhere else in the file — using `const` in the destructured `Promise.all` result above is correct and matches existing usage (grep confirms `convoRows` is only read, never reassigned, elsewhere in the file).

- [ ] **Step 2: Verify the diff**

Run: `git diff supabase/functions/chat/index.ts`
Expected: the two queries now inside one `Promise.all`, `character`/`charErr`/`convoRows` destructured from the parallel result, `convo` still declared with `let` and still assigned from `convoRows?.[0]`. No other line in the file references `convoRows` for reassignment.

Run: `grep -n "convoRows" supabase/functions/chat/index.ts`
Expected: only the declaration/destructuring site and the `convo = convoRows?.[0]` read — no `convoRows =` reassignment anywhere.

- [ ] **Step 3: Commit**

```bash
git add supabase/functions/chat/index.ts
git commit -m "perf(chat): parallelize character and conversation lookup"
```

---

### Task 5: Deploy and manually verify

**Files:** none (deploy + manual test only)

**Interfaces:**
- Consumes: the finished `supabase/functions/chat/index.ts` from Tasks 1-4.
- Produces: nothing — final task.

- [ ] **Step 1: Deploy**

```bash
npx supabase functions deploy chat --project-ref ohpvhgwjmrfjclnumgnm
```

Expected: `"message":"Deployed Functions."`.

- [ ] **Step 2: Confirm the new version is live**

```bash
npx supabase functions list --project-ref ohpvhgwjmrfjclnumgnm
```

Confirm the `chat` entry's `version` incremented again and `updated_at` is recent.

- [ ] **Step 3: Manual smoke test — main reply path**

Send a normal text message. Confirm the reply is correct/in-character and references memories/behaviors correctly if any exist for that conversation (unchanged from before — only fetch timing changed, not content).

- [ ] **Step 4: Manual smoke test — photoDownloadReaction path**

Download a private/intimate generated photo in-app for the first time. Confirm the reaction line still comes back correctly, still references shared history/memories/behaviors if present, and still marks `character_photos.reacted = true` (unaffected by this change, but worth confirming the branch still completes end-to-end).

- [ ] **Step 5: Sanity-check latency**

Time a few chat replies before/after (e.g. via the app's perceived response time, or timestamps in Supabase function logs) — expect a modest improvement, not a specific guaranteed number. No hard pass/fail threshold; this step is directional confirmation, not a regression gate.
