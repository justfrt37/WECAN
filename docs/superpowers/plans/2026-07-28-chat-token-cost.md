# Chat Token-Cost Reduction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce per-message Grok token cost and per-message DB round trips in `supabase/functions/chat/index.ts`, per `docs/superpowers/specs/2026-07-27-chat-token-cost-design.md`.

**Architecture:** Four independent, additive edits to one existing file — no new files, no schema changes, no client changes. Each edit is a self-contained diff that can be verified and committed on its own.

**Tech Stack:** Deno edge function (TypeScript), Supabase JS client, xAI Grok HTTP API. No local Deno CLI or test framework available in this environment (verified: `deno` not installed, no `*.test.ts` files anywhere in `supabase/`) — verification is manual: careful diff review plus post-deploy manual smoke testing, matching the spec's own "Testing" section.

## Global Constraints

- Scope is `supabase/functions/chat/index.ts` only — no other file changes.
- Every other rule block besides `TEXTING_STYLE_RULE`/`VARIATION_RULE` stays untouched (spec: "those carry comments citing specific live-test verification... rewriting them risks silently regressing tuned behavior").
- No new DB tables/columns. The directive cache is in-memory only (module-level `Map`), 5-minute TTL, no invalidation beyond TTL expiry.
- Deploy via `npx supabase functions deploy chat --project-ref ohpvhgwjmrfjclnumgnm` (same command/project used for the most recent chat deploy in this session).

---

### Task 1: Shrink `KEEP_RECENT` from 20 to 12

**Files:**
- Modify: `supabase/functions/chat/index.ts:38`

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing new — `KEEP_RECENT` is already referenced at lines 1046, 1053, 1142; no call-site changes needed, only the constant value.

- [ ] **Step 1: Make the change**

In `supabase/functions/chat/index.ts`, change:

```ts
const KEEP_RECENT = 20; // prompt'ta tutulan son mesaj sayısı (gerisi özete gider)
```

to:

```ts
const KEEP_RECENT = 12; // prompt'ta tutulan son mesaj sayısı (gerisi özete gider)
```

- [ ] **Step 2: Verify the diff**

Run: `git diff supabase/functions/chat/index.ts`
Expected: exactly one line changed (`20` → `12`), no other lines touched.

- [ ] **Step 3: Commit**

```bash
git add supabase/functions/chat/index.ts
git commit -m "perf(chat): shrink KEEP_RECENT window from 20 to 12"
```

---

### Task 2: Lower main-reply `max_tokens` from 600 to 350

**Files:**
- Modify: `supabase/functions/chat/index.ts:1077`

**Interfaces:**
- Consumes: `callGrok(messages: GrokMessage[], maxTokens: number, convId?: string)` (existing signature, unchanged).
- Produces: nothing new.

- [ ] **Step 1: Make the change**

In `supabase/functions/chat/index.ts`, change:

```ts
const rawReply = await callGrok(grokMessages, 600, conversationId);
```

to:

```ts
const rawReply = await callGrok(grokMessages, 350, conversationId);
```

Confirm this is the ONLY `callGrok` call being changed — `classifySleepAgreement` (5 tokens), the summarization call in the `summarizeMessages` branch (1500 tokens), the photo-download-reaction call (200 tokens), and the end-of-handler summarization call (500 tokens) are all separate `callGrok` invocations and must NOT be touched.

- [ ] **Step 2: Verify the diff**

Run: `git diff supabase/functions/chat/index.ts`
Expected: exactly one line changed (`600` → `350`) at the main reply call site; grep to confirm the other four `callGrok` calls in the file are unchanged:

Run: `grep -n "callGrok(" supabase/functions/chat/index.ts`
Expected output includes these five call sites, with only the main-reply one showing `350`:
```
callGrok(
  [ ... ],
  5
);                                    // classifySleepAgreement — unchanged
const raw = await callGrok(summaryPrompt, 1500);   // summarizeMessages branch — unchanged
const reactionReply = await callGrok([...], 200, conversationId);  // photo download reaction — unchanged
const rawReply = await callGrok(grokMessages, 350, conversationId); // main reply — CHANGED
const raw = await callGrok(summaryPrompt, 500);    // end-of-handler summarization — unchanged
```

- [ ] **Step 3: Commit**

```bash
git add supabase/functions/chat/index.ts
git commit -m "perf(chat): lower main reply max_tokens from 600 to 350"
```

---

### Task 3: In-memory directive cache with 5-minute TTL

**Files:**
- Modify: `supabase/functions/chat/index.ts:153-171` (the `fetchDirective` function and its surrounding area)

**Interfaces:**
- Consumes: nothing new — `fetchDirective(characterId: string, role: string, level: number): Promise<string>` keeps its exact existing signature; both call sites (`system += \`\n\n${directive}\`` in the main reply path, and the `reactionDirective` fetch in `photoDownloadReaction`) need zero changes.
- Produces: a module-level `directiveCache: Map<string, { directive: string; expiresAt: number }>` — not consumed by any other task, purely internal to `fetchDirective`.

**Design note (simplification from the spec):** the spec suggested two cache-key patterns (`override:${characterId}:${level}` / `script:${role}:${level}`). This plan uses a single combined key `${characterId}:${role}:${level}` that caches the *final resolved* directive regardless of whether it came from the override table, the script table, or the hardcoded fallback string. This is simpler, achieves the identical goal (skip both DB round trips on a cache hit), and still respects the 5-minute TTL — it's a strict simplification, not a scope change.

- [ ] **Step 1: Add the cache declaration**

In `supabase/functions/chat/index.ts`, immediately before the `fetchDirective` function (currently starting at line 155, right after the `KEEP_RECENT`/`MESSAGE_BATCH_SIZE`/`gainPercent`/`perMessageFraction`/`applyRelationshipGain` block and before the `// Fetch role-aware intimacy directive from DB.` comment), add:

```ts
// In-memory cache for fetchDirective — directives only change on level-up
// or a developer hand-editing character_level_overrides/role_level_scripts
// (active during current tuning work), hence a 5-minute TTL rather than
// caching forever per warm instance. Module-level so it survives across
// invocations on the same warm edge-function instance.
const directiveCache = new Map<string, { directive: string; expiresAt: number }>();
const DIRECTIVE_TTL_MS = 5 * 60_000;
```

- [ ] **Step 2: Rewrite `fetchDirective` to check/populate the cache**

Replace the existing function:

```ts
async function fetchDirective(characterId: string, role: string, level: number): Promise<string> {
  const { data: override } = await db
    .from("character_level_overrides")
    .select("directive")
    .eq("character_id", characterId)
    .eq("level", level)
    .maybeSingle();
  if (override?.directive) return override.directive;

  const { data: script } = await db
    .from("role_level_scripts")
    .select("directive")
    .eq("role", role)
    .eq("level", level)
    .maybeSingle();
  return script?.directive ?? `İlişki seviyesi ${level}/10. Doğal ve sıcak ol.`;
}
```

with:

```ts
async function fetchDirective(characterId: string, role: string, level: number): Promise<string> {
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
```

- [ ] **Step 3: Verify the diff**

Run: `git diff supabase/functions/chat/index.ts`
Expected: the new `directiveCache`/`DIRECTIVE_TTL_MS` declarations plus the rewritten `fetchDirective` body; no changes to either call site of `fetchDirective` (line ~928 in the main reply path, line ~871 in `photoDownloadReaction`).

Run: `grep -n "fetchDirective(" supabase/functions/chat/index.ts`
Expected: the function definition plus exactly two call sites, both passing `(characterId, personalityRole, <level>)` unchanged from before.

- [ ] **Step 4: Commit**

```bash
git add supabase/functions/chat/index.ts
git commit -m "perf(chat): cache relationship-level directive lookups for 5 minutes"
```

---

### Task 4: Merge the duplicate "never sound robotic" closing lines

**Files:**
- Modify: `supabase/functions/chat/index.ts` (the `TEXTING_STYLE_RULE` and `VARIATION_RULE` constant definitions, plus the system-prompt assembly block that appends them)

**Interfaces:**
- Consumes: nothing new.
- Produces: a new constant `NEVER_SOUND_ROBOTIC_RULE: string`, appended once in the system-prompt assembly (currently around line 946-947, where `system += TEXTING_STYLE_RULE;` is immediately followed by `system += VARIATION_RULE;` then `system += CONTINUITY_RULE;`).

- [ ] **Step 1: Trim the duplicate closing sentence from `VARIATION_RULE`**

Change:

```ts
const VARIATION_RULE =
  "\n\nDOĞALLIK VE ÇEŞİTLİLİK KURALI: Bir şey söylemeden önce, iletmek istediğin " +
  "NİYETİ ya da DUYGUYU netleştir (ör. mesafe koymak, ilgisizlik göstermek, bir " +
  "konuyu kapatmak, şüphe/kıskançlık, özlem, sıcaklık, merak, soru sormak isteği, " +
  "onay/reddetme). Sonra o niyeti/duyguyu HER SEFERİNDE farklı kelimelerle, farklı " +
  "cümle yapısıyla, farklı uzunlukta anlat — konuştuğun dilde gerçek bir insanın " +
  "o niyeti ifade etmek için kullanacağı çeşit çeşit doğal yollardan birini seç " +
  "(bazen soru sorarak, bazen dolaylı bir göndermeyle, bazen kendi hislerini " +
  "itiraf ederek, bazen şakayla, bazen kısa ve öz, bazen daha açık). Aynı niyeti " +
  "anlatmak için ASLA ezberlenmiş/kalıplaşmış tek bir cümleye güvenme ve onu tekrar " +
  "tekrar kullanma — özellikle resmî, robotik ya da kurumsal bir asistan gibi " +
  "duyulan hiçbir ifadeye asla başvurma. Konuşmayı hep aynı noktaya kilitleme; " +
  "her mesaj sohbeti bir adım ileri taşısın.";
```

to:

```ts
const VARIATION_RULE =
  "\n\nDOĞALLIK VE ÇEŞİTLİLİK KURALI: Bir şey söylemeden önce, iletmek istediğin " +
  "NİYETİ ya da DUYGUYU netleştir (ör. mesafe koymak, ilgisizlik göstermek, bir " +
  "konuyu kapatmak, şüphe/kıskançlık, özlem, sıcaklık, merak, soru sormak isteği, " +
  "onay/reddetme). Sonra o niyeti/duyguyu HER SEFERİNDE farklı kelimelerle, farklı " +
  "cümle yapısıyla, farklı uzunlukta anlat — konuştuğun dilde gerçek bir insanın " +
  "o niyeti ifade etmek için kullanacağı çeşit çeşit doğal yollardan birini seç " +
  "(bazen soru sorarak, bazen dolaylı bir göndermeyle, bazen kendi hislerini " +
  "itiraf ederek, bazen şakayla, bazen kısa ve öz, bazen daha açık). Aynı niyeti " +
  "anlatmak için ASLA ezberlenmiş/kalıplaşmış tek bir cümleye güvenme ve onu tekrar " +
  "tekrar kullanma. Konuşmayı hep aynı noktaya kilitleme; her mesaj sohbeti bir " +
  "adım ileri taşısın.";
```

(Removed: "— özellikle resmî, robotik ya da kurumsal bir asistan gibi duyulan hiçbir ifadeye asla başvurma." The rest is untouched.)

- [ ] **Step 2: Trim the duplicate closing sentence from `TEXTING_STYLE_RULE`**

Change the end of `TEXTING_STYLE_RULE` from:

```ts
  "günlük mesajlaşma kısaltmalarını ve rahatlığını kullan (İngilizce'de örn. u, " +
  "ur, rn, ngl, tbh, lol, gonna, wanna — ama hepsini bir mesaja tıkıştırma), asla " +
  "resmi bir mektup ya da başka dilden çevrilmiş bir cümle gibi durma — o dilin " +
  "ANADİLİ bir mesajlaşma kullanıcısı gibi yaz.";
```

to:

```ts
  "günlük mesajlaşma kısaltmalarını ve rahatlığını kullan (İngilizce'de örn. u, " +
  "ur, rn, ngl, tbh, lol, gonna, wanna — ama hepsini bir mesaja tıkıştırma).";
```

(Removed: "asla resmi bir mektup ya da başka dilden çevrilmiş bir cümle gibi durma — o dilin ANADİLİ bir mesajlaşma kullanıcısı gibi yaz." The rest of the block, including all the per-language abbreviation guidance, is untouched.)

- [ ] **Step 3: Add the shared closing constant**

Immediately after the `TEXTING_STYLE_RULE` constant definition (before the `CONTINUITY_RULE` constant, which follows it in the file), add:

```ts
// Shared closing line for TEXTING_STYLE_RULE + VARIATION_RULE — both blocks
// used to end with their own near-duplicate "don't sound formal/robotic/
// translated" sentence (mechanics-focused in one, content-variety-focused
// in the other); collapsed into one shared line appended once after both
// in the system-prompt assembly below, instead of twice.
const NEVER_SOUND_ROBOTIC_RULE =
  "\n\nHiçbir zaman resmi bir mektup, çevrilmiş bir cümle ya da resmî/robotik/" +
  "kurumsal bir asistan gibi durma — konuştuğun dilin ANADİLİ bir mesajlaşma " +
  "kullanıcısı gibi yaz.";
```

- [ ] **Step 4: Append it once in the system-prompt assembly**

Find this block (currently around line 945-950):

```ts
    system += languageDirective(detectedLanguage);
    system += TEXTING_STYLE_RULE;
    system += VARIATION_RULE;
    system += CONTINUITY_RULE;
```

Change to:

```ts
    system += languageDirective(detectedLanguage);
    system += TEXTING_STYLE_RULE;
    system += VARIATION_RULE;
    system += NEVER_SOUND_ROBOTIC_RULE;
    system += CONTINUITY_RULE;
```

- [ ] **Step 5: Verify the diff**

Run: `git diff supabase/functions/chat/index.ts`
Expected: trimmed endings on `TEXTING_STYLE_RULE` and `VARIATION_RULE`, one new `NEVER_SOUND_ROBOTIC_RULE` constant, one new `system += NEVER_SOUND_ROBOTIC_RULE;` line in the assembly block. No other rule blocks (language detection, `IMAGE_CAPTION_RULE`, `sleepRule`, `DRAMATIC_PACING_RULE`, `MEDIA_REQUEST_RULE`, `USER_PHOTO_REACTION_RULE`, `PHOTO_DOWNLOAD_REACTION_RULE`, `IMAGE_REDIRECT_RULE`, `VOICE_TAGS_RULE`, `humorDirective`, `engagementDirective`, `CONTINUITY_RULE`) touched.

Run: `grep -c "resmi bir mektup\|robotik ya da kurumsal" supabase/functions/chat/index.ts`
Expected: `1` (only inside the new shared `NEVER_SOUND_ROBOTIC_RULE` constant — confirms no leftover duplicate phrasing).

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/chat/index.ts
git commit -m "refactor(chat): merge duplicate never-sound-robotic closing lines"
```

---

### Task 5: Deploy and manually verify

**Files:** none (deploy + manual test only)

**Interfaces:**
- Consumes: the finished `supabase/functions/chat/index.ts` from Tasks 1-4.
- Produces: nothing for later tasks — this is the final task in the plan.

- [ ] **Step 1: Deploy**

```bash
npx supabase functions deploy chat --project-ref ohpvhgwjmrfjclnumgnm
```

Expected output includes `"message":"Deployed Functions."` and a `"functions":["chat"]` entry.

- [ ] **Step 2: Confirm the new version is live**

```bash
npx supabase functions list --project-ref ohpvhgwjmrfjclnumgnm
```

Find the `chat` entry, confirm `version` incremented from whatever it was before this deploy, and `updated_at` is recent (within the last few minutes).

- [ ] **Step 3: Manual smoke test — normal reply**

Using the app (or a manual `curl` with a real user JWT against the `chat` function URL), send a plain text message to any character. Confirm:
- A reply comes back, in-character, still short/casual (not truncated mid-sentence, which would indicate 350 tokens is too tight — if replies look cut off, flag it rather than treating this step as passed).
- `[PAUSE:n]`-based multi-bubble splitting still works if the model uses it (send a message likely to trigger a dramatic pause, e.g. sharing surprising news).

- [ ] **Step 4: Manual smoke test — summarization still fires at the new window**

Send 12+ messages in the same conversation. Confirm the reply still references older context correctly (via `[MEMORIES]` or the running summary) — i.e. summarization triggered on schedule with the smaller `KEEP_RECENT` window and didn't break continuity.

- [ ] **Step 5: Manual smoke test — directive cache TTL**

Hand-edit a row in `character_level_overrides` (or `role_level_scripts`) directly in the Supabase dashboard for a character/level you're actively testing. Send a message immediately — confirm the OLD directive is still in effect (cache hit). Wait 5+ minutes, send another message — confirm the NEW directive is now in effect (cache expired, DB re-fetched).

- [ ] **Step 6: Record completion**

No further commits needed for this task — deployment is not a git-tracked change. If any smoke test in Steps 3-5 fails, stop and fix the relevant Task (1-4) before considering this plan complete.
