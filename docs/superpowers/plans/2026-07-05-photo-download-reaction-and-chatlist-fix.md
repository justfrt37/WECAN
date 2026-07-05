# Photo Download + Private-Photo Reaction, and Chat-List Ordering Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user download a character's photo from the fullscreen chat viewer; if that photo was generated as private/intimate, the character reacts with one Grok-reasoned in-character complaint the first time it's downloaded. Separately, fix the chat list so the newest conversation always sorts to the top and reliably refreshes when a message is injected outside the normal send/receive flow.

**Architecture:** Two independent subsystems sharing no code, built as one plan because both touch the chat surface. (1) Privacy classification happens once, at photo-generation time, in `chat-image`'s edge function, stored on the `generated_photos` row; a new `photoDownloadReaction` mode on the existing `chat` edge function is queried once per photo the first time it's downloaded, reusing that function's existing character/directive/language-detection plumbing. (2) `ChatListView` gets a real sort key and a new reactive trigger (`CharacterStore.conversationsVersion`) that out-of-band message injectors bump.

**Tech Stack:** Supabase Edge Functions (Deno/TypeScript), Postgres, SwiftUI/`@Observable`, `PHPhotoLibrary`.

## Global Constraints

- **No automated test suite exists in this repo** — no XCTest target for the iOS app, no test framework for the Deno edge functions. Every prior backend change in this project was verified with live `curl` calls against the deployed function (see e.g. the 7-language `chat` test earlier this session); every prior Swift change was verified by manual read-through only, since this environment has no Xcode.app (`xcode-select -p` → Command Line Tools only) and SourceKit diagnostics are unreliable noise here. This plan follows the same pattern: backend tasks end with a `curl` verification step showing exact expected output; Swift tasks end with a manual read-through checklist instead of a compiled test. **Flag to the user that a real Xcode build + on-device smoke test is still owed** before considering the Swift side done (matches the standing item already in project memory for every other Swift feature built this way).
- Deploy commands use `SUPABASE_ACCESS_TOKEN=<SUPABASE_MANAGEMENT_PAT — see project memory, never hardcode> npx supabase functions deploy <name> --project-ref ohpvhgwjmrfjclnumgnm --no-verify-jwt`, run from `/Users/furkanozsoy/Desktop/Projects/aigf/WECAN`.
- DDL is applied via the Management API (no linked local DB): `curl -s -X POST "https://api.supabase.com/v1/projects/ohpvhgwjmrfjclnumgnm/database/query" -H "Authorization: Bearer <SUPABASE_MANAGEMENT_PAT — see project memory, never hardcode>" -H "Content-Type: application/json" -d '{"query":"<SQL>"}'`.
- Every new/edited instructional Grok prompt string must be written in **English** (existing project convention — see `[[feedback_grok_prompts_english]]`), even though the rest of `chat/index.ts`'s comments are Turkish.
- Reuse existing patterns exactly: `voiceChat`/`imageReactionChat` are the precedent for adding a new boolean mode to the `chat` function; `NotificationDelegate.injectMessage` is the precedent for injecting an assistant message into local storage outside the normal send flow.

---

### Task 1: `generated_photos` migration — privacy + reacted columns

**Files:**
- Create: `supabase/migrations/005_generated_photos_private_flag.sql`

**Interfaces:**
- Produces: `generated_photos.is_private boolean not null default false`, `generated_photos.reacted boolean not null default false` — read/written by Task 2 (sets `is_private` on insert) and Task 3 (reads both, sets `reacted` on the reaction call).

- [ ] **Step 1: Write the migration file**

```sql
-- supabase/migrations/005_generated_photos_private_flag.sql
alter table generated_photos
  add column is_private boolean not null default false,
  add column reacted boolean not null default false;
```

- [ ] **Step 2: Apply it against the live database**

```bash
curl -s -X POST "https://api.supabase.com/v1/projects/ohpvhgwjmrfjclnumgnm/database/query" \
  -H "Authorization: Bearer <SUPABASE_MANAGEMENT_PAT — see project memory, never hardcode>" \
  -H "Content-Type: application/json" \
  -d '{"query":"alter table generated_photos add column is_private boolean not null default false, add column reacted boolean not null default false;"}'
```

Expected: `{"result": ...}` with no `error` key (an empty/void result is normal for `ALTER TABLE`).

- [ ] **Step 3: Verify the columns exist**

```bash
curl -s -X POST "https://api.supabase.com/v1/projects/ohpvhgwjmrfjclnumgnm/database/query" \
  -H "Authorization: Bearer <SUPABASE_MANAGEMENT_PAT — see project memory, never hardcode>" \
  -H "Content-Type: application/json" \
  -d '{"query":"select column_name, data_type, column_default from information_schema.columns where table_name = '\''generated_photos'\'' order by ordinal_position;"}'
```

Expected: a row list including `is_private | boolean | false` and `reacted | boolean | false`.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/005_generated_photos_private_flag.sql
git commit -m "$(cat <<'EOF'
feat: add is_private/reacted columns to generated_photos

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Classify photo privacy at generation time (`chat-image`)

**Files:**
- Modify: `supabase/functions/chat-image/index.ts:212-221` (add a new function near `callGrokText`), `:378-421` (use it, add to insert)

**Interfaces:**
- Consumes: `callGrokText(messages, maxTokens): Promise<string>` (already exists, line 212).
- Produces: `classifyPrivacy(imagePrompt: string): Promise<boolean>` — new function. `generated_photos.is_private` gets populated on insert.

- [ ] **Step 1: Add the classifier function right after `callGrokText`**

In `supabase/functions/chat-image/index.ts`, immediately after the existing `callGrokText` function (ends at line 221), add:

```typescript
// Reuses the already-composed photo-director prompt text to decide if the
// photo reads as private/intimate — no vision call needed, the SUBJECT/
// OUTFIT/POSE fields already describe exactly what will be in frame.
async function classifyPrivacy(imagePrompt: string): Promise<boolean> {
  const raw = await callGrokText(
    [
      {
        role: "system",
        content:
          "You are a content classifier. Given a photo description, answer " +
          "with exactly one word: YES if the described photo is private, " +
          "intimate, sexy, revealing, or something a person wouldn't want " +
          "shared publicly; NO if it's an ordinary, presentable photo. " +
          "Answer with only YES or NO, nothing else.",
      },
      { role: "user", content: imagePrompt },
    ],
    5
  );
  return raw.trim().toUpperCase().startsWith("Y");
}
```

- [ ] **Step 2: Run classification in parallel with image generation**

In the same file, find this block (around line 378-393):

```typescript
    let photoUrl: string;
    try {
      const imagePrompt = await composeImagePrompt({
        appearance: appearanceContext({
          name: character.name,
          profession: character.profession,
          tagline: character.tagline,
          builderSelections: character.builder_selections ?? null,
        }),
        category,
        userPrompt,
        hasBaseline: baselineImageUrl !== null,
        context: conversationContext(history, summary),
      });
      const bytes = await fetchGeneratedImageBytes(imagePrompt, baselineImageUrl);
      photoUrl = await uploadGeneratedImage(bytes);
    } catch (e) {
      console.error("chat-image generation failed:", String(e));
      return json({ error: "image_generation_failed" }, 502);
    }
```

Replace it with:

```typescript
    let photoUrl: string;
    let isPrivate = false;
    try {
      const imagePrompt = await composeImagePrompt({
        appearance: appearanceContext({
          name: character.name,
          profession: character.profession,
          tagline: character.tagline,
          builderSelections: character.builder_selections ?? null,
        }),
        category,
        userPrompt,
        hasBaseline: baselineImageUrl !== null,
        context: conversationContext(history, summary),
      });
      const [bytes, privacyResult] = await Promise.all([
        fetchGeneratedImageBytes(imagePrompt, baselineImageUrl),
        classifyPrivacy(imagePrompt),
      ]);
      photoUrl = await uploadGeneratedImage(bytes);
      isPrivate = privacyResult;
    } catch (e) {
      console.error("chat-image generation failed:", String(e));
      return json({ error: "image_generation_failed" }, 502);
    }
```

- [ ] **Step 3: Store the classification on insert**

Find (around line 415-421):

```typescript
    const { error: insErr } = await db.from("generated_photos").insert({
      conversation_id: convo.id,
      character_id: characterId,
      user_id: uid,
      url: photoUrl,
    });
    if (insErr) console.error("generated_photos insert failed:", insErr.message);
```

Replace with:

```typescript
    const { error: insErr } = await db.from("generated_photos").insert({
      conversation_id: convo.id,
      character_id: characterId,
      user_id: uid,
      url: photoUrl,
      is_private: isPrivate,
    });
    if (insErr) console.error("generated_photos insert failed:", insErr.message);
```

- [ ] **Step 4: Deploy**

```bash
cd /Users/furkanozsoy/Desktop/Projects/aigf/WECAN
SUPABASE_ACCESS_TOKEN=<SUPABASE_MANAGEMENT_PAT — see project memory, never hardcode> npx supabase functions deploy chat-image --project-ref ohpvhgwjmrfjclnumgnm --no-verify-jwt
```

Expected: `{"project_ref":"ohpvhgwjmrfjclnumgnm","functions":["chat-image"],...,"message":"Deployed Functions."}`

- [ ] **Step 5: Verify classification actually runs end-to-end**

Get a fresh anonymous JWT and call `chat-image` with a prompt that should clearly classify as private, then check the row:

```bash
JWT=$(curl -s -X POST "https://ohpvhgwjmrfjclnumgnm.supabase.co/auth/v1/signup" \
  -H "apikey: sb_publishable_AdvrSU0EhHDJyWsOtGGhZg_DHca3OaB" \
  -H "Content-Type: application/json" -d '{}' | python3 -c "import json,sys;print(json.load(sys.stdin)['access_token'])")

curl -s -X POST "https://ohpvhgwjmrfjclnumgnm.supabase.co/functions/v1/chat-image" \
  -H "apikey: sb_publishable_AdvrSU0EhHDJyWsOtGGhZg_DHca3OaB" \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"characterId":"00000000-0000-0000-0000-000000000002","prompt":"a very intimate boudoir photo in lingerie on the bed"}'
```

Expected: `{"url":"https://...supabase.co/storage/v1/.../generated/....png"}`. Then check the row was marked private (need the service-role key since this is a fresh anon user with no RLS-visible rows otherwise — use the DB query endpoint instead):

```bash
curl -s -X POST "https://api.supabase.com/v1/projects/ohpvhgwjmrfjclnumgnm/database/query" \
  -H "Authorization: Bearer <SUPABASE_MANAGEMENT_PAT — see project memory, never hardcode>" \
  -H "Content-Type: application/json" \
  -d '{"query":"select url, is_private, reacted from generated_photos order by created_at desc limit 1;"}'
```

Expected: the row matching the URL just generated, with `is_private: true`.

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/chat-image/index.ts
git commit -m "$(cat <<'EOF'
feat: classify generated photos as private/intimate at generation time

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `photoDownloadReaction` mode on the `chat` function

**Files:**
- Modify: `supabase/functions/chat/index.ts` (add a new rule constant near `MEDIA_REQUEST_RULE`; add a new mode branch; widen the existing `detectedLanguage` computation)

**Interfaces:**
- Consumes: `fetchDirective(characterId, role, level): Promise<string>`, `languageDirective(language: string|null): string`, `detectReplyLanguage(userMessage: string, clientHistory): string|null`, `callGrok(messages, maxTokens): Promise<string>` — all already exist in this file.
- Produces: request shape `{ photoDownloadReaction: true, photoURL: string, characterId, systemPrompt, clientHistory, localSummary, level, ... }` → response `{ reply: string | null }`. Task 4 (`ChatService.swift`) is the consumer of this shape.

- [ ] **Step 1: Add the `PHOTO_DOWNLOAD_REACTION_RULE` constant**

Find `MEDIA_REQUEST_RULE` in `supabase/functions/chat/index.ts` (ends around line 115, right before the "Belirli kalıp cümleleri..." comment). Immediately after it, add:

```typescript
// Fires once per photo, only the first time a private/intimate generated
// photo is downloaded (server checks generated_photos.reacted — see the
// photoDownloadReaction branch below). Written in English per project
// convention for instructional prompts.
const PHOTO_DOWNLOAD_REACTION_RULE =
  "\n\n[PHOTO DOWNLOAD REACTION] The user just downloaded a private/intimate " +
  "photo of you to their own device. Write ONE short, natural, in-character " +
  "reaction to this — a cute, genuine complaint or tease about it (e.g. " +
  "concern about it being shared, playful mock-offense, flustered teasing) — " +
  "whatever actually fits your personality and how close you are with the " +
  "user right now. Reason this out yourself in the moment; never reuse a " +
  "fixed template line, and never sound robotic or like a canned response. " +
  "Output ONLY the reaction line itself, nothing else.";
```

- [ ] **Step 2: Widen `detectedLanguage` to also cover this mode**

Find this line (added earlier this session, near the `currentActivity` computation):

```typescript
    const detectedLanguage = userMessage
      ? detectReplyLanguage(userMessage, clientHistory)
      : null;
```

Replace with:

```typescript
    const detectedLanguage = (userMessage || body.photoDownloadReaction === true)
      ? detectReplyLanguage(userMessage ?? "", clientHistory)
      : null;
```

This lets language detection run from `clientHistory` alone when there's no `userMessage` (the download-reaction case).

- [ ] **Step 3: Add the new mode branch**

Find the end of the "GEÇMİŞ MODU" block:

```typescript
    // === GEÇMİŞ MODU — clientHistory yoksa ===
    if (!useClientHistory && (!userMessage || userMessage.trim() === "")) {
      const { data: msgs } = await db
        .from("messages")
        .select("role, content, kind")
        .eq("conversation_id", conversationId)
        .order("created_at", { ascending: true });
      return json({
        conversationId,
        history: msgs ?? [],
        xp: convo.xp ?? 0,
        level: convo.relationship_level ?? 1,
      });
    }

    // === CEVAP MODU: sistem promptunu hazırla ===
```

Insert a new branch between them (right before the `// === CEVAP MODU` comment):

```typescript
    // === FOTOĞRAF İNDİRME TEPKİSİ MODU (photoDownloadReaction: true) ===
    // Kullanıcı özel/mahrem işaretli bir fotoğrafı cihazına indirdi. userMessage
    // YOK — bu gerçek bir sohbet turu değil, XP/seviye/mesaj geçmişi etkilenmez.
    if (body.photoDownloadReaction === true) {
      const photoURL: string = body.photoURL;
      if (!photoURL) return json({ reply: null });

      const { data: photoRow } = await db
        .from("generated_photos")
        .select("id, is_private, reacted")
        .eq("url", photoURL)
        .eq("user_id", uid)
        .maybeSingle();

      if (!photoRow || !photoRow.is_private || photoRow.reacted) {
        return json({ reply: null });
      }

      const reactionLevel: number = convo.relationship_level ?? 1;
      const reactionDirective = await fetchDirective(characterId, personalityRole, reactionLevel);
      let reactionSystem = systemPrompt;
      reactionSystem += `\n\n${reactionDirective}`;
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

      reactionSystem += languageDirective(detectedLanguage);
      reactionSystem += PHOTO_DOWNLOAD_REACTION_RULE;

      const reactionReply = await callGrok(
        [
          { role: "system", content: reactionSystem },
          { role: "user", content: "[The user just saved this photo to their device.]" },
        ],
        200
      );

      await db.from("generated_photos").update({ reacted: true }).eq("id", photoRow.id);

      return json({ reply: reactionReply });
    }

    // === CEVAP MODU: sistem promptunu hazırla ===
```

- [ ] **Step 4: Deploy**

```bash
cd /Users/furkanozsoy/Desktop/Projects/aigf/WECAN
SUPABASE_ACCESS_TOKEN=<SUPABASE_MANAGEMENT_PAT — see project memory, never hardcode> npx supabase functions deploy chat --project-ref ohpvhgwjmrfjclnumgnm --no-verify-jwt
```

Expected: `{"project_ref":"ohpvhgwjmrfjclnumgnm","functions":["chat"],...,"message":"Deployed Functions."}`

- [ ] **Step 5: Verify the new mode against the private photo generated in Task 2**

Reuse the same `$JWT` from Task 2 (or sign up fresh) and the photo `url` returned there:

```bash
curl -s -X POST "https://ohpvhgwjmrfjclnumgnm.supabase.co/functions/v1/chat" \
  -H "apikey: sb_publishable_AdvrSU0EhHDJyWsOtGGhZg_DHca3OaB" \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"characterId":"00000000-0000-0000-0000-000000000002","systemPrompt":"","clientHistory":[],"localSummary":"","level":1,"photoDownloadReaction":true,"photoURL":"<paste the url from Task 2 step 5>"}'
```

Expected: `{"reply":"<some short natural in-character line>"}`, non-null.

Run the exact same call again immediately:

Expected: `{"reply":null}` — confirms the "only first download" `reacted` gate works.

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/chat/index.ts
git commit -m "$(cat <<'EOF'
feat: add photoDownloadReaction mode — one-time in-character complaint when a private photo is downloaded

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `ChatService.sendPhotoDownloadReaction`

**Files:**
- Modify: `aiGirlfriend/Services/ChatService.swift`

**Interfaces:**
- Consumes: `Config.chatFunctionURL`, `UserDefaultsManager.shared.accessToken`, `Config.supabaseAnonKey`, existing `ChatRequest`/`ChatResponse`/`WireHistoryMessage`/`RequestExtra`/`perform(...)` (all in this file).
- Produces: `ChatService.sendPhotoDownloadReaction(character: Character, localMessages: [Message], summary: String, level: Int, photoURL: URL) async throws -> String?` — consumed by Task 6 (`ChatViewModel`).

- [ ] **Step 1: Add fields to `ChatRequest`**

Find the `ChatRequest` struct (line 13-41) and add two fields at the end, right before the closing brace:

```swift
    /// true ise bu bir fotoğraf-indirme tepkisi çağrısıdır — userMessage yok,
    /// sunucu generated_photos'ta bu url'i arayıp özel/mahrem VE henüz tepki
    /// verilmemişse Grok'a bir kere tepki yazdırır (bkz. chat/index.ts).
    let photoDownloadReaction: Bool?
    let photoURL: String?
```

- [ ] **Step 2: Add a `.photoDownloadReaction` case to `RequestExtra` and wire it in `perform`**

Find `RequestExtra` (line 291-296):

```swift
    private enum RequestExtra {
        case none
        case clear
        case localHistory([WireHistoryMessage], summary: String?)
        case summarize([WireHistoryMessage], existing: String)
    }
```

Replace with:

```swift
    private enum RequestExtra {
        case none
        case clear
        case localHistory([WireHistoryMessage], summary: String?)
        case summarize([WireHistoryMessage], existing: String)
        case photoDownloadReaction([WireHistoryMessage], summary: String?, photoURL: String)
    }
```

Find the `switch extra` block inside `perform` (line 331-342):

```swift
        var clearConversation: Bool? = nil
        var clientHistory: [WireHistoryMessage]? = nil
        var localSummary: String? = nil
        var summarizeMessages: [WireHistoryMessage]? = nil
        var existingSummary: String? = nil

        switch extra {
        case .none:
            break
        case .clear:
            clearConversation = true
        case .localHistory(let h, let s):
            clientHistory = h
            localSummary = s
        case .summarize(let msgs, let existing):
            summarizeMessages = msgs
            existingSummary = existing
        }
```

Replace with:

```swift
        var clearConversation: Bool? = nil
        var clientHistory: [WireHistoryMessage]? = nil
        var localSummary: String? = nil
        var summarizeMessages: [WireHistoryMessage]? = nil
        var existingSummary: String? = nil
        var photoDownloadReaction: Bool? = nil
        var photoURL: String? = nil

        switch extra {
        case .none:
            break
        case .clear:
            clearConversation = true
        case .localHistory(let h, let s):
            clientHistory = h
            localSummary = s
        case .summarize(let msgs, let existing):
            summarizeMessages = msgs
            existingSummary = existing
        case .photoDownloadReaction(let h, let s, let url):
            clientHistory = h
            localSummary = s
            photoDownloadReaction = true
            photoURL = url
        }
```

Find the `ChatRequest(...)` construction right after (line 344-361) and add the two new arguments:

```swift
        let body = ChatRequest(
            characterId: character.id.uuidString.lowercased(),
            systemPrompt: character.systemPrompt,
            userMessage: userMessage,
            clientHistory: clientHistory,
            localSummary: localSummary,
            summarizeMessages: summarizeMessages,
            existingSummary: existingSummary,
            level: level,
            lastMessageAt: lastMessageAt.map { $0.timeIntervalSince1970 * 1000 },
            clientNow: Date().timeIntervalSince1970 * 1000,
            tzOffsetMinutes: TimeZone.current.secondsFromGMT() / 60,
            clearConversation: clearConversation,
            voiceChat: voiceChat,
            imageReactionChat: imageReactionChat,
            currentActivity: currentActivity,
            previousSchedule: previousSchedule,
            photoDownloadReaction: photoDownloadReaction,
            photoURL: photoURL
        )
```

- [ ] **Step 3: Add the public method**

Add this new method right after `generateChatImage` (which ends at line 227):

```swift
    /// Fotoğraf indirme tepkisi — sadece indirilen fotoğraf özel/mahrem
    /// işaretliyse VE daha önce hiç tepki verilmemişse sunucu bir cevap döner
    /// (bkz. chat/index.ts photoDownloadReaction). `nil` dönerse (foto özel
    /// değil, ya da zaten bir kere tepki verilmiş) çağıran hiçbir şey yapmaz.
    func sendPhotoDownloadReaction(
        character: Character,
        localMessages: [Message],
        summary: String,
        level: Int,
        photoURL: URL
    ) async throws -> String? {
        let wireHistory = localMessages
            .filter { $0.imageURL == nil }
            .suffix(20)
            .map { WireHistoryMessage(role: $0.role.rawValue, content: $0.content) }
        let resp = try await perform(
            character: character,
            userMessage: nil,
            extra: .photoDownloadReaction(wireHistory, summary: summary.isEmpty ? nil : summary, photoURL: photoURL.absoluteString),
            level: level
        )
        return resp.reply
    }
```

- [ ] **Step 4: Manual read-through verification**

No test target exists (see Global Constraints). Re-read the diff and confirm:
1. `ChatRequest`'s new fields are both optional (`Bool?`, `String?`) so every other existing call site (which doesn't set them) still encodes correctly via `JSONEncoder` (nil-valued optionals are simply omitted, matching how `voiceChat`/`imageReactionChat` etc. already behave).
2. `RequestExtra.photoDownloadReaction`'s associated values match exactly what `sendPhotoDownloadReaction` passes.
3. `perform`'s new `case .photoDownloadReaction` sets all four locals used by the `ChatRequest(...)` call below it.

- [ ] **Step 5: Commit**

```bash
git add aiGirlfriend/Services/ChatService.swift
git commit -m "$(cat <<'EOF'
feat: add ChatService.sendPhotoDownloadReaction

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `CharacterStore.conversationsVersion` + bump on out-of-band injection

**Files:**
- Modify: `aiGirlfriend/Services/CharacterStore.swift`
- Modify: `aiGirlfriend/Services/NotificationDelegate.swift:127-135`

**Interfaces:**
- Produces: `CharacterStore.conversationsVersion: Int` — observed by Task 8 (`ChatListView`), bumped by `NotificationDelegate.injectMessage` (this task) and by `ChatViewModel.reactToPrivateDownload` (Task 6).

- [ ] **Step 1: Add the property**

In `aiGirlfriend/Services/CharacterStore.swift`, find:

```swift
    /// Karakter başına sohbet geçmişi önbelleği (Chat History'de doldurulur,
    /// ChatView anında açılsın diye — her seferinde yeniden yüklenmez).
    var chatCache: [UUID: [Message]] = [:]
```

Add right after it:

```swift

    /// Bumped any time a message is injected into LocalConversationStore
    /// OUTSIDE the normal ChatViewModel send/receive flow (bot notifications,
    /// photo-download reactions) — ChatListView observes this to reload/
    /// reorder even when nothing touched `typingCharacterIDs`.
    var conversationsVersion: Int = 0
```

- [ ] **Step 2: Bump it from `NotificationDelegate.injectMessage`**

In `aiGirlfriend/Services/NotificationDelegate.swift`, find:

```swift
    private func injectMessage(_ text: String, for characterID: UUID) {
        // "Liked You" bildirimleri hiç konuşulmamış botlar için gelir — o yüzden
        // henüz LocalConversationStore kaydı yok; bu mesaj sohbetin İLK mesajı olur.
        var stored = LocalConversationStore.shared.load(for: characterID)
            ?? LocalConversationStore.Stored(messages: [], xp: 0, level: 1, summary: "", summarizedCount: 0)
        stored.messages.append(Message(role: .assistant, content: text))
        LocalConversationStore.shared.save(stored, for: characterID)
        store.chatCache.removeValue(forKey: characterID) // force ChatViewModel to reload fresh, not the stale cache
    }
```

Replace with:

```swift
    private func injectMessage(_ text: String, for characterID: UUID) {
        // "Liked You" bildirimleri hiç konuşulmamış botlar için gelir — o yüzden
        // henüz LocalConversationStore kaydı yok; bu mesaj sohbetin İLK mesajı olur.
        var stored = LocalConversationStore.shared.load(for: characterID)
            ?? LocalConversationStore.Stored(messages: [], xp: 0, level: 1, summary: "", summarizedCount: 0)
        stored.messages.append(Message(role: .assistant, content: text))
        LocalConversationStore.shared.save(stored, for: characterID)
        store.chatCache.removeValue(forKey: characterID) // force ChatViewModel to reload fresh, not the stale cache
        store.conversationsVersion += 1
    }
```

- [ ] **Step 3: Manual read-through verification**

Confirm `CharacterStore` is `@Observable` (it is, line 10) so `conversationsVersion` mutations are automatically observable by any SwiftUI view reading it — no extra wiring needed on the property itself.

- [ ] **Step 4: Commit**

```bash
git add aiGirlfriend/Services/CharacterStore.swift aiGirlfriend/Services/NotificationDelegate.swift
git commit -m "$(cat <<'EOF'
feat: add CharacterStore.conversationsVersion, bump on notification message injection

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `ChatViewModel.reactToPrivateDownload`

**Files:**
- Modify: `aiGirlfriend/ViewModels/ChatViewModel.swift`

**Interfaces:**
- Consumes: `service.sendPhotoDownloadReaction(character:localMessages:summary:level:photoURL:) async throws -> String?` (Task 4), `LocalConversationStore.shared.load(for:)`, `realMessages()`, `updateCache()`, `store?.conversationsVersion` (Task 5).
- Produces: `ChatViewModel.reactToPrivateDownload(imageURL: URL)` — consumed by Task 7 (`ChatView`'s `FullscreenImageView` download button).

- [ ] **Step 1: Add the method**

Add this right after `sendImageRequest()` (which ends at line 425, just before the `applyPostReplyEffects` doc-comment block):

```swift
    /// Fotoğraf tam ekranda indirilince çağrılır (bkz. ChatView.FullscreenImageView).
    /// Sunucu foto özel/mahrem işaretli VE daha önce hiç tepki verilmemişse bir
    /// cevap döner; öbür türlü `nil` döner ve hiçbir şey olmaz. Bu GERÇEK bir
    /// sohbet turu DEĞİL — XP/seviye etkilenmez, kullanıcı mesajı gösterilmez.
    func reactToPrivateDownload(imageURL: URL) {
        Task {
            let stored = LocalConversationStore.shared.load(for: character.id)
            // `try?` on an `async throws -> String?` flattens to a single-level
            // `String?` in Swift 5 (SE-0230) — nil here means either the call
            // threw OR the server legitimately returned `{ reply: null }`
            // (not private / already reacted). Both cases are a silent no-op.
            guard let reply = try? await service.sendPhotoDownloadReaction(
                character: character,
                localMessages: realMessages(),
                summary: stored?.summary ?? "",
                level: relationshipLevel,
                photoURL: imageURL
            ) else { return }
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            messages.append(Message(role: .assistant, content: trimmed))
            updateCache()
            store?.conversationsVersion += 1
        }
    }
```

- [ ] **Step 2: Manual read-through verification**

Confirm `service` (line 43, `private let service = ChatService()`), `realMessages()` (line 549), `updateCache()` (line 563), and `store` (line 44, `var store: CharacterStore?`) are all already members of this class at the scope this method is added — no new imports or properties needed. Also confirm the `try?`-flattening reasoning in the code comment above: `sendPhotoDownloadReaction`'s declared return type is already `String?`, so per SE-0230 (active by default in Swift 5 mode) `try?` produces `String?`, not `String??` — do not add a second `?` when unwrapping `reply`.

- [ ] **Step 3: Commit**

```bash
git add aiGirlfriend/ViewModels/ChatViewModel.swift
git commit -m "$(cat <<'EOF'
feat: add ChatViewModel.reactToPrivateDownload

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Download button in `FullscreenImageView` + `PHPhotoLibrary` save + Info.plist key

**Files:**
- Modify: `aiGirlfriend/Views/ChatView.swift:1-7` (import), `:92-99` (fullScreenCover wiring), `:621-647` (`FullscreenImageView`)
- Modify: `aiGirlfriend.xcodeproj/project.pbxproj` (both Debug and Release `INFOPLIST_KEY_*` blocks)

**Interfaces:**
- Consumes: `ImageCache.shared.image(for: URL) -> UIImage?` (already exists), `viewModel.reactToPrivateDownload(imageURL:)` (Task 6).

- [ ] **Step 1: Add the Info.plist usage-description key**

In `aiGirlfriend.xcodeproj/project.pbxproj`, find (appears twice — once per build config):

```
				INFOPLIST_KEY_NSMicrophoneUsageDescription = "Microphone access is needed to send voice messages.";
				INFOPLIST_KEY_NSSpeechRecognitionUsageDescription = "Speech recognition is used to convert your voice to text before sending.";
```

Replace **both occurrences** with:

```
				INFOPLIST_KEY_NSMicrophoneUsageDescription = "Microphone access is needed to send voice messages.";
				INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription = "Needed to save photos to your device when you tap download.";
				INFOPLIST_KEY_NSSpeechRecognitionUsageDescription = "Speech recognition is used to convert your voice to text before sending.";
```

(Use a find-and-replace-all across the file — the two occurrences are identical and both need the same new line added, alphabetically between the existing Microphone/SpeechRecognition keys.)

- [ ] **Step 2: Add the `Photos` import**

In `aiGirlfriend/Views/ChatView.swift`, find:

```swift
import SwiftUI
```

Replace with:

```swift
import SwiftUI
import Photos
```

- [ ] **Step 3: Update `FullscreenImageView`**

Find the entire struct (lines 621-647):

```swift
private struct FullscreenImageView: View {
    let url: URL
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            CachedImage(url: url) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                ProgressView().tint(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture { onDismiss() }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .padding(16)
        }
    }
}
```

Replace with:

```swift
private struct FullscreenImageView: View {
    let url: URL
    let onDismiss: () -> Void
    let onDownloaded: () -> Void

    @State private var saveMessage: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            CachedImage(url: url) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                ProgressView().tint(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture { onDismiss() }

            HStack(spacing: 10) {
                Button(action: downloadImage) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.5), in: Circle())
                }
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.5), in: Circle())
                }
            }
            .padding(16)

            if let saveMessage {
                Text(saveMessage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.7), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 40)
                    .allowsHitTesting(false)
            }
        }
    }

    private func downloadImage() {
        guard let image = ImageCache.shared.image(for: url) else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else {
                    showSaveMessage("Photo access needed to save")
                    return
                }
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                } completionHandler: { success, _ in
                    DispatchQueue.main.async {
                        if success {
                            showSaveMessage("Saved to Photos")
                            onDownloaded()
                        } else {
                            showSaveMessage("Couldn't save photo")
                        }
                    }
                }
            }
        }
    }

    private func showSaveMessage(_ text: String) {
        saveMessage = text
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            saveMessage = nil
        }
    }
}
```

- [ ] **Step 4: Wire `onDownloaded` at the call site**

Find (lines 92-99):

```swift
        .fullScreenCover(isPresented: Binding(
            get: { fullscreenImageURL != nil },
            set: { if !$0 { fullscreenImageURL = nil } }
        )) {
            if let url = fullscreenImageURL {
                FullscreenImageView(url: url) { fullscreenImageURL = nil }
            }
        }
```

Replace with:

```swift
        .fullScreenCover(isPresented: Binding(
            get: { fullscreenImageURL != nil },
            set: { if !$0 { fullscreenImageURL = nil } }
        )) {
            if let url = fullscreenImageURL {
                FullscreenImageView(url: url, onDismiss: { fullscreenImageURL = nil }) {
                    viewModel.reactToPrivateDownload(imageURL: url)
                }
            }
        }
```

- [ ] **Step 5: Manual read-through verification**

No test target / no Xcode in this environment (see Global Constraints). Re-read the diff and confirm:
1. `FullscreenImageView`'s new `onDownloaded` parameter is supplied at both the call site above and has no other call sites in the file (`grep -n "FullscreenImageView(" aiGirlfriend/Views/ChatView.swift` should show exactly one construction, matching the new 3-argument form).
2. `PHAssetChangeRequest` and `PHPhotoLibrary` are both part of the `Photos` framework import added in Step 2 — no additional framework needed.
3. The `project.pbxproj` edit applied to **both** the Debug and Release blocks (`grep -c "INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription" aiGirlfriend.xcodeproj/project.pbxproj` should print `2`).
4. Flag to the user: this task is unverified beyond static review — a real Xcode build and on-device tap-through (download a photo, confirm it lands in Photos, confirm permission-denied path shows the inline message) is still owed, per the Global Constraints note.

- [ ] **Step 6: Commit**

```bash
git add aiGirlfriend/Views/ChatView.swift aiGirlfriend.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat: add photo download button to fullscreen chat image viewer

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: `ChatListView` — sort by recency + new reactive trigger

**Files:**
- Modify: `aiGirlfriend/Views/ChatListView.swift:37-115`

**Interfaces:**
- Consumes: `CharacterStore.conversationsVersion` (Task 5).

- [ ] **Step 1: Add a private date-parsing helper next to the existing one**

Find (near the bottom of the file, around line 356):

```swift
/// ISO8601 zaman damgasını kısa göreli metne çevirir (şimdi, 5dk, 2sa, Dün…).
private func relativeTime(_ iso: String?) -> String {
```

Add a new helper right above it:

```swift
/// ISO8601 zaman damgasını `Date`'e çevirir — sıralama için (bkz. ChatListView.load()).
private func parseISO8601(_ iso: String?) -> Date? {
    guard let iso else { return nil }
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fmt.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
}

```

- [ ] **Step 2: Sort `items` by recency in `load()`**

Find the end of `load()` (lines 110-115):

```swift
            return ChatItem(character: ch, conversationID: conv.id,
                            last: last, unread: unread, updatedAt: conv.updatedAt)
        }
        isLoading = false
        saveCachedItems(items)
    }
```

Replace with:

```swift
            return ChatItem(character: ch, conversationID: conv.id,
                            last: last, unread: unread, updatedAt: conv.updatedAt)
        }
        items.sort { lhs, rhs in
            let lhsDate = parseISO8601(lhs.last?.createdAt) ?? parseISO8601(lhs.updatedAt) ?? .distantPast
            let rhsDate = parseISO8601(rhs.last?.createdAt) ?? parseISO8601(rhs.updatedAt) ?? .distantPast
            return lhsDate > rhsDate
        }
        isLoading = false
        saveCachedItems(items)
    }
```

- [ ] **Step 3: Add the new reactive trigger**

Find:

```swift
        .task { await load() }
        .onChange(of: store.typingCharacterIDs) { Task { await load() } }
    }
```

Replace with:

```swift
        .task { await load() }
        .onChange(of: store.typingCharacterIDs) { Task { await load() } }
        .onChange(of: store.conversationsVersion) { Task { await load() } }
    }
```

- [ ] **Step 4: Manual read-through verification**

No test target / no Xcode in this environment (see Global Constraints). Re-read the diff and confirm:
1. `ChatItem.last` is `LastMessage?` and `LastMessage.createdAt` is a non-optional `String` (confirmed in `ConversationsService.swift`), so `lhs.last?.createdAt` correctly type-checks as `String?` going into `parseISO8601`.
2. `ChatItem.updatedAt` is `String?` (matches `parseISO8601`'s parameter type directly, no unwrap needed beyond what's shown).
3. `store.conversationsVersion` (Task 5) is accessible here since `ChatListView` already holds `@Environment(CharacterStore.self) private var store` (line 19).
4. Flag to the user: since this fix can't be compiled/run here, the actual manual QA (open Chat tab, trigger a jealousy/ghosted notification or a private-photo-download reaction while the tab is open, confirm the row jumps to top without leaving the tab) is still owed — same caveat as Task 7.

- [ ] **Step 5: Commit**

```bash
git add aiGirlfriend/Views/ChatListView.swift
git commit -m "$(cat <<'EOF'
fix: sort chat list by most-recent message, add reactive trigger for out-of-band message injection

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Post-plan: still owed (cannot be done in this environment)

- Real Xcode build + on-device smoke test of Tasks 6-8 (no Xcode.app available here — see Global Constraints).
- Manual QA: download a non-private photo (confirm silent save, no reaction message); download a private photo twice (confirm reaction fires once, second download stays silent); trigger a notification-injected message while `ChatListView` is open (confirm it reorders to top without leaving/re-entering the tab).
