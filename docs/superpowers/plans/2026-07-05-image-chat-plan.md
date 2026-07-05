# Chat Image-Generation Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `ChatView`'s static quick-reply chip row with two mode buttons ("Send me a voice" / "Send me a photo"); the photo mode generates a real Grok (xAI) image from the user's own typed description instead of picking a random pre-set photo, and privately stores it per-user in a new "Your Photos" Gallery section.

**Architecture:** New Supabase edge function `chat-image` (mirrors `create-character`'s existing `generateImageOnly` xAI-image-gen code path) generates and uploads the photo, gets-or-creates the user's conversation row, and inserts a private row into a new `generated_photos` table. `chat/index.ts` gains an `imageReactionChat` flag that lets Grok optionally add a short in-character follow-up caption via a `[[no_caption]]` marker (mirrors the existing `[[photo]]` marker convention). Client-side, `ChatViewModel.sendImageRequest()` mirrors the existing `sendVoiceRequest()` method; `ChatView`'s quick-reply row becomes two mutually-exclusive mode toggle buttons.

**Tech Stack:** Supabase Edge Functions (Deno + TypeScript), PostgreSQL (Supabase), SwiftUI, `@Observable`, xAI Grok API (`grok-imagine-image` for images, `grok-4-1-fast-non-reasoning` for text).

## Global Constraints

- No test framework exists in this repo (no Xcode CLI available in this sandbox, no Deno test setup) — verification is via `curl` against deployed functions, standalone `deno run`/`swift` scripts for pure logic, and manual code review. This matches the project's established verification pattern (see `project_changelog.md`).
- **Never write the Supabase Management PAT or service-role key literally into any file that gets committed** (a plan doc leaking the PAT into git history is a real past incident — see project memory `next_steps.md` item 12). All deploy/DDL commands below reference `$SUPABASE_PAT` as an environment variable to export in your shell before running — substitute the actual value from project memory (`project_overview.md`) at the shell, never paste it into a file.
- Supabase project ref: `ohpvhgwjmrfjclnumgnm`. Deploy command shape: `SUPABASE_ACCESS_TOKEN=$SUPABASE_PAT npx supabase functions deploy <name> --project-ref ohpvhgwjmrfjclnumgnm --no-verify-jwt`. DDL command shape: `curl -s -X POST "https://api.supabase.com/v1/projects/ohpvhgwjmrfjclnumgnm/database/query" -H "Authorization: Bearer $SUPABASE_PAT" -H "Content-Type: application/json" -d '{"query":"<SQL>"}'`.
- Do not commit or push unless the user explicitly asks (project-standing rule) — stage changes and stop after each task's commit step; ask before pushing.
- No fallback-to-pool-photo on generation failure — surface an error only (explicit product decision).
- Do not gate this feature behind PRO/daily caps — explicitly deferred.

---

### Task 1: `generated_photos` table + RLS

**Files:**
- Create: `supabase/migrations/004_generated_photos.sql`

**Interfaces:**
- Produces: table `generated_photos(id uuid, conversation_id uuid, character_id uuid, user_id uuid, url text, created_at timestamptz)`, columns `character_id`/`user_id` denormalized directly onto the row (not resolved via a join) so the client can query `?character_id=eq.<id>` directly and rely on RLS to scope to the caller — avoids requiring the client to have SELECT access to `conversations` just to resolve an embedded-resource filter.

- [ ] **Step 1: Write the migration file**

```sql
-- supabase/migrations/004_generated_photos.sql
create table generated_photos (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references conversations(id) on delete cascade,
  character_id uuid not null references characters(id) on delete cascade,
  user_id uuid not null,
  url text not null,
  created_at timestamptz not null default now()
);

alter table generated_photos enable row level security;

create policy "select own generated photos" on generated_photos
  for select using (user_id = auth.uid());
```

- [ ] **Step 2: Apply the migration via the Management API DDL endpoint**

Export the PAT in your shell first (do not write it into any file):
```bash
export SUPABASE_PAT=<paste from project_overview.md memory, not into any file>
```

Run (reads the migration file's contents via jq to safely JSON-escape it):
```bash
curl -s -X POST "https://api.supabase.com/v1/projects/ohpvhgwjmrfjclnumgnm/database/query" \
  -H "Authorization: Bearer $SUPABASE_PAT" \
  -H "Content-Type: application/json" \
  -d "$(jq -Rs '{query: .}' < supabase/migrations/004_generated_photos.sql)"
```
Expected: `{"result":[...]}` or similar success payload, no `"error"` key.

- [ ] **Step 3: Verify the table and policy exist**

```bash
curl -s -X POST "https://api.supabase.com/v1/projects/ohpvhgwjmrfjclnumgnm/database/query" \
  -H "Authorization: Bearer $SUPABASE_PAT" \
  -H "Content-Type: application/json" \
  -d '{"query":"select column_name, data_type from information_schema.columns where table_name = '"'"'generated_photos'"'"' order by ordinal_position;"}'
```
Expected: 6 rows — `id`, `conversation_id`, `character_id`, `user_id`, `url`, `created_at`.

```bash
curl -s -X POST "https://api.supabase.com/v1/projects/ohpvhgwjmrfjclnumgnm/database/query" \
  -H "Authorization: Bearer $SUPABASE_PAT" \
  -H "Content-Type: application/json" \
  -d '{"query":"select polname, qual from pg_policies where tablename = '"'"'generated_photos'"'"';"}'
```
Expected: one row, `polname = "select own generated photos"`.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/004_generated_photos.sql
git commit -m "feat: add generated_photos table for private AI-generated chat photos"
```

---

### Task 2: `chat-image` edge function

**Files:**
- Create: `supabase/functions/chat-image/index.ts`

**Interfaces:**
- Consumes: table `generated_photos` from Task 1 (columns `conversation_id`, `character_id`, `user_id`, `url`).
- Produces: `POST /functions/v1/chat-image` — Request `{ characterId: string, prompt: string }` with `Authorization: Bearer <JWT>`. Response `{ url: string }` (200) or `{ error: string }` (401/400/502). This is the exact shape `ChatService.generateChatImage` (Task 4) will call.

- [ ] **Step 1: Write the edge function**

```typescript
// supabase/functions/chat-image/index.ts
//
// Kullanicinin sohbette yazdigi tarif metninden xAI ile bir fotoğraf üretir.
// create-character'in generateImageOnly modundaki aynı xAI görüntü kodunu
// kullanır (ayrı fonksiyon, kod paylaşımı yok — bu repodaki her edge
// function kendi içinde bağımsızdır).
//
//   İstek:  { characterId, prompt }  (Authorization: Bearer <JWT> zorunlu)
//   Cevap:  { url }  veya  { error }

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const XAI_API_KEY = Deno.env.get("XAI_API_KEY") ?? "";
const XAI_IMAGE_URL = "https://api.x.ai/v1/images/generations";
const IMAGE_MODEL = "grok-imagine-image";
const IMAGE_RESOLUTION = "2k";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

function userIdFromJWT(authHeader: string | null): string | null {
  if (!authHeader) return null;
  const jwt = authHeader.replace("Bearer ", "").trim();
  const parts = jwt.split(".");
  if (parts.length < 2) return null;
  try {
    let b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    while (b64.length % 4) b64 += "=";
    return JSON.parse(atob(b64)).sub ?? null;
  } catch { return null; }
}

interface BuilderSelections {
  category?: string;
  hairstyle?: string;
  hair_color?: string;
  eye_shape?: string;
  eye_color?: string;
  nose_shape?: string;
  skin_tone?: string;
}

function buildImagePrompt(opts: {
  name: string;
  profession: string | null;
  tagline: string | null;
  builderSelections: BuilderSelections | null;
  userPrompt: string;
}): string {
  const styleCue: Record<string, string> = {
    Realistic: "photorealistic photo, natural lighting, high detail, DSLR quality",
    Anime: "anime style illustration, clean line art, vibrant colors, detailed shading",
    Fantasy: "fantasy digital painting, magical atmosphere, painterly detail",
    "Sci-Fi": "sci-fi digital art, futuristic aesthetic, cinematic lighting",
  };
  const bs = opts.builderSelections;
  const style = styleCue[bs?.category ?? "Realistic"] ?? styleCue.Realistic;

  let appearance: string;
  if (bs && (bs.hairstyle || bs.hair_color || bs.eye_shape || bs.eye_color)) {
    appearance =
      `a person with ${(bs.hairstyle ?? "").toLowerCase()} ${(bs.hair_color ?? "").toLowerCase()} hair, ` +
      `${(bs.eye_shape ?? "").toLowerCase()} ${(bs.eye_color ?? "").toLowerCase()} eyes, ` +
      `${(bs.nose_shape ?? "").toLowerCase()} nose, ${(bs.skin_tone ?? "").toLowerCase()} skin tone`;
  } else {
    // Catalog character with no recorded appearance fields — best-effort style
    // cue only, no guaranteed visual consistency (same limitation as create-character
    // has for anything without builder_selections).
    appearance = `${opts.name}${opts.profession ? `, a ${opts.profession.toLowerCase()}` : ""}`;
  }

  return `${style} of ${appearance}, ${opts.userPrompt}`;
}

async function fetchGeneratedImageBytes(prompt: string): Promise<Uint8Array> {
  const r = await fetch(XAI_IMAGE_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${XAI_API_KEY}` },
    body: JSON.stringify({ model: IMAGE_MODEL, prompt, n: 1, resolution: IMAGE_RESOLUTION }),
  });
  if (!r.ok) throw new Error(`Image gen ${r.status}: ${await r.text()}`);
  const d = await r.json();
  const item = d?.data?.[0];
  if (item?.b64_json) {
    return Uint8Array.from(atob(item.b64_json), (c: string) => c.charCodeAt(0));
  }
  if (item?.url) {
    const imgResp = await fetch(item.url);
    if (!imgResp.ok) throw new Error(`Image download ${imgResp.status}`);
    return new Uint8Array(await imgResp.arrayBuffer());
  }
  throw new Error("No image data in xAI response");
}

async function uploadGeneratedImage(bytes: Uint8Array): Promise<string> {
  const path = `generated/${crypto.randomUUID()}.png`;
  const { error } = await db.storage.from("characters").upload(path, bytes, {
    contentType: "image/png",
    upsert: false,
  });
  if (error) throw new Error(`Storage upload failed: ${error.message}`);
  const { data } = db.storage.from("characters").getPublicUrl(path);
  return data.publicUrl;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);

    const b = await req.json();
    const characterId: string = b.characterId;
    const userPrompt: string = (b.prompt ?? "").toString().trim();
    if (!characterId) return json({ error: "characterId required" }, 400);
    if (!userPrompt) return json({ error: "prompt required" }, 400);

    const { data: character, error: charErr } = await db
      .from("characters")
      .select("name, profession, tagline, builder_selections")
      .eq("id", characterId)
      .maybeSingle();
    if (charErr || !character) return json({ error: "character not found" }, 400);

    const imagePrompt = buildImagePrompt({
      name: character.name,
      profession: character.profession,
      tagline: character.tagline,
      builderSelections: character.builder_selections ?? null,
      userPrompt,
    });

    let photoUrl: string;
    try {
      const bytes = await fetchGeneratedImageBytes(imagePrompt);
      photoUrl = await uploadGeneratedImage(bytes);
    } catch (e) {
      console.error("chat-image generation failed:", String(e));
      return json({ error: "image_generation_failed" }, 502);
    }

    // Konuşmayı bul ya da oluştur (chat/add-character-note ile aynı desen).
    let { data: convo } = await db
      .from("conversations")
      .select("id")
      .eq("user_id", uid)
      .eq("character_id", characterId)
      .maybeSingle();
    if (!convo) {
      const ins = await db
        .from("conversations")
        .insert({ user_id: uid, character_id: characterId })
        .select("id")
        .single();
      convo = ins.data!;
    }

    const { error: insErr } = await db.from("generated_photos").insert({
      conversation_id: convo.id,
      character_id: characterId,
      user_id: uid,
      url: photoUrl,
    });
    if (insErr) console.error("generated_photos insert failed:", insErr.message);

    return json({ url: photoUrl });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
```

- [ ] **Step 2: Deploy**

```bash
SUPABASE_ACCESS_TOKEN=$SUPABASE_PAT npx supabase functions deploy chat-image --project-ref ohpvhgwjmrfjclnumgnm --no-verify-jwt
```
Expected: `Deployed Function chat-image`.

- [ ] **Step 3: Verify with a live curl call**

Get a real character ID first (any live catalog character):
```bash
curl -s "https://ohpvhgwjmrfjclnumgnm.supabase.co/rest/v1/characters?select=id,name&limit=1" \
  -H "apikey: sb_publishable_AdvrSU0EhHDJyWsOtGGhZg_DHca3OaB"
```
Note the returned `id`. This test call intentionally omits Authorization to confirm the auth gate:
```bash
curl -s -X POST "https://ohpvhgwjmrfjclnumgnm.supabase.co/functions/v1/chat-image" \
  -H "Content-Type: application/json" \
  -d '{"characterId":"<id from above>","prompt":"a selfie at the beach"}'
```
Expected: `{"error":"unauthorized"}`. A full authenticated test (with a real user JWT, costs real money per call) is deferred to Task 6's end-to-end manual test.

- [ ] **Step 4: Commit**

```bash
git add supabase/functions/chat-image/index.ts
git commit -m "feat: add chat-image edge function for Grok-generated chat photos"
```

---

### Task 3: `chat/index.ts` — `imageReactionChat` flag + caption marker

**Files:**
- Modify: `supabase/functions/chat/index.ts:294` (near existing `voiceChat` flag), `:372-374` (where `VOICE_TAGS_RULE` is conditionally appended)

**Interfaces:**
- Consumes: nothing new from other tasks.
- Produces: request flag `imageReactionChat: boolean` (same shape/spot as existing `voiceChat`); when true, the reply is either a short in-character line or the literal string `[[no_caption]]`. `ChatService.sendWithLocalHistory` (Task 4) sends this flag; `ChatViewModel.sendImageRequest()` (Task 5) checks the literal marker string `"[[no_caption]]"` against the trimmed reply.

- [ ] **Step 1: Add the `IMAGE_CAPTION_RULE` constant**

Insert directly after the existing `VOICE_TAGS_RULE` constant (`chat/index.ts:145`, right before the `humorDirective` function):

```typescript
// Foto isteği görsel olarak zaten gönderildi (istemci chat-image fonksiyonundan
// aldığı URL'i ayrıca ekledi) — bu çağrı SADECE isteğe bağlı bir metin tepkisi
// üretir. Model bazen tepki vermek istemeyebilir; bunu [[no_caption]] işaretiyle
// bildirir (bkz. PHOTO_INSTRUCTION'daki [[photo]] işareti ile aynı yöntem).
const IMAGE_CAPTION_RULE =
  "\n\n[FOTOĞRAF TEPKİSİ] Kullanıcının istediği fotoğrafı az önce gönderdin. " +
  "İstersen kısa, doğal, karakterine uygun bir tepki cümlesi yaz. Tepki vermek " +
  "istemiyorsan cevap olarak SADECE ve TAM OLARAK şunu yaz: [[no_caption]]";
```

- [ ] **Step 2: Read the flag from the request body**

Locate `const voiceChat: boolean = body.voiceChat === true;` (`chat/index.ts:294`) and add directly below it:

```typescript
    // Fotoğraf isteği tepki modu mu? (bkz. IMAGE_CAPTION_RULE)
    const imageReactionChat: boolean = body.imageReactionChat === true;
```

- [ ] **Step 3: Append the rule to the system prompt**

Locate:
```typescript
    if (voiceChat) {
      system += VOICE_TAGS_RULE;
    }
```
(`chat/index.ts:372-374`) and add directly after it:

```typescript
    if (imageReactionChat) {
      system += IMAGE_CAPTION_RULE;
    }
```

- [ ] **Step 4: Deploy**

```bash
SUPABASE_ACCESS_TOKEN=$SUPABASE_PAT npx supabase functions deploy chat --project-ref ohpvhgwjmrfjclnumgnm --no-verify-jwt
```
Expected: `Deployed Function chat`.

- [ ] **Step 5: Verify existing behavior is untouched**

```bash
curl -s -X POST "https://ohpvhgwjmrfjclnumgnm.supabase.co/functions/v1/chat" \
  -H "Content-Type: application/json" \
  -d '{"characterId":"<id from Task 2>","systemPrompt":"You are a friendly test bot.","clientHistory":[],"userMessage":"hey","level":1}'
```
Expected: `{"error":"unauthorized"}` (same as before this change — this function has always required a JWT; confirms the edit didn't break the auth gate or introduce a syntax error that would 500 instead).

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/chat/index.ts
git commit -m "feat: add imageReactionChat flag and no-caption marker to chat function"
```

---

### Task 4: `ChatService.swift` — `generateChatImage` + `imageReactionChat` param

**Files:**
- Modify: `aiGirlfriend/Config.swift` (add `chatImageFunctionURL`)
- Modify: `aiGirlfriend/Services/ChatService.swift`

**Interfaces:**
- Consumes: `Config.supabaseURL`, `Config.supabaseAnonKey`, `UserDefaultsManager.shared.accessToken` (all pre-existing).
- Produces: `ChatService.generateChatImage(character: Character, prompt: String) async throws -> URL`. `ChatService.sendWithLocalHistory(character:localMessages:summary:userMessage:level:lastMessageAt:voiceChat:imageReactionChat:)` gains one new parameter, default `false`, backward compatible with all existing call sites (`send()`'s equivalent doesn't call this signature directly — only `ChatViewModel.send()`/`sendVoiceRequest()` do, both via the `voiceChat:` keyword, so adding a defaulted trailing parameter doesn't break them).

- [ ] **Step 1: Add the function URL to `Config.swift`**

Add after `voiceMessageTTSFunctionURL` (`Config.swift:33-35`):

```swift
    /// Kullanıcının sohbette yazdığı tarife göre xAI ile fotoğraf üretir.
    static var chatImageFunctionURL: URL {
        URL(string: "\(supabaseURL)/functions/v1/chat-image")!
    }
```

- [ ] **Step 2: Add the `imageReactionChat` field to `ChatRequest` and thread it through `perform`**

In `ChatService.swift:13-32`, add one field to `ChatRequest` directly below `voiceChat`:
```swift
    let voiceChat: Bool?
    /// true ise Grok'a "az önce fotoğraf gönderdin, istersen kısa bir tepki yaz,
    /// istemiyorsan [[no_caption]] yaz" talimatı eklenir (bkz. chat-image akışı).
    let imageReactionChat: Bool?
```

In `perform` (`ChatService.swift:207-214`), add a parameter:
```swift
    private func perform(
        character: Character,
        userMessage: String?,
        extra: RequestExtra = .none,
        level: Int? = nil,
        lastMessageAt: Date? = nil,
        voiceChat: Bool = false,
        imageReactionChat: Bool = false
    ) async throws -> ChatResponse {
```

In the same function's `ChatRequest(...)` construction (`ChatService.swift:241-255`), add the field:
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
            imageReactionChat: imageReactionChat
        )
```

- [ ] **Step 3: Add the `imageReactionChat` parameter to `sendWithLocalHistory` and pass it through**

Replace `sendWithLocalHistory`'s signature and body (`ChatService.swift:138-164`):
```swift
    func sendWithLocalHistory(
        character: Character,
        localMessages: [Message],
        summary: String,
        userMessage: String,
        level: Int,
        lastMessageAt: Date? = nil,
        voiceChat: Bool = false,
        imageReactionChat: Bool = false
    ) async throws -> ChatReply {
        let wireHistory = localMessages
            .filter { $0.imageURL == nil }
            .suffix(20)
            .map { WireHistoryMessage(role: $0.role.rawValue, content: $0.content) }
        let resp = try await perform(
            character: character,
            userMessage: userMessage,
            extra: .localHistory(wireHistory, summary: summary.isEmpty ? nil : summary),
            level: level,
            lastMessageAt: lastMessageAt,
            voiceChat: voiceChat,
            imageReactionChat: imageReactionChat
        )
        return ChatReply(
            reply: resp.reply ?? "",
            level: resp.level ?? level,
            photoURL: resp.photoUrl.flatMap(URL.init(string:))
        )
    }
```

- [ ] **Step 4: Add `generateChatImage`**

Add as a new method on `ChatService`, directly after `sendWithLocalHistory`:

```swift
    private struct ChatImageRequest: Codable {
        let characterId: String
        let prompt: String
    }

    private struct ChatImageResponse: Codable {
        let url: String?
        let error: String?
    }

    /// "Send me a photo" modu — kullanıcının tarifinden xAI ile gerçek bir
    /// fotoğraf üretir (bkz. ChatViewModel.sendImageRequest).
    func generateChatImage(character: Character, prompt: String) async throws -> URL {
        var request = URLRequest(url: Config.chatImageFunctionURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bearer = UserDefaultsManager.shared.accessToken ?? Config.supabaseAnonKey
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(
            ChatImageRequest(characterId: character.id.uuidString.lowercased(), prompt: prompt)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatServiceError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw ChatServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let decoded = try? JSONDecoder().decode(ChatImageResponse.self, from: data),
              let urlString = decoded.url, let url = URL(string: urlString) else {
            throw ChatServiceError.decoding
        }
        return url
    }
```

- [ ] **Step 5: Manual review pass (no Xcode in this sandbox — see Global Constraints)**

Re-read the full edited `ChatService.swift` file and confirm:
- `ChatRequest`'s `Codable` synthesis still matches 1:1 with its properties (no orphan `CodingKeys`) — it has none, so this is a non-issue, but confirm no `CodingKeys` enum was accidentally introduced.
- Every existing call site of `sendWithLocalHistory` (grep `sendWithLocalHistory(` in `ChatViewModel.swift`) still compiles conceptually — both existing call sites use keyword arguments and omit `imageReactionChat`, which is fine since it has a default.

```bash
grep -n "sendWithLocalHistory(" /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend/ViewModels/ChatViewModel.swift
```
Expected: 2 matches (inside `send()` and `sendVoiceRequest()`), neither passing `imageReactionChat:` — confirms the default keeps them compiling unchanged.

- [ ] **Step 6: Commit**

```bash
git add aiGirlfriend/Config.swift aiGirlfriend/Services/ChatService.swift
git commit -m "feat: add generateChatImage service call and imageReactionChat flag"
```

---

### Task 5: `ChatViewModel.swift` — `sendImageRequest()`

**Files:**
- Modify: `aiGirlfriend/ViewModels/ChatViewModel.swift`

**Interfaces:**
- Consumes: `ChatService.generateChatImage(character:prompt:)` and `sendWithLocalHistory(...:imageReactionChat:)` from Task 4.
- Produces: `ChatViewModel.isImageArmed: Bool`, `ChatViewModel.isSendingImageReply: Bool`, `ChatViewModel.sendImageRequest()` — all consumed by `ChatView` in Task 6.

- [ ] **Step 1: Add the new state properties**

Add directly after the existing `isSendingVoiceReply` declaration (`ChatViewModel.swift:229`):

```swift
    /// Fotoğraf isteği bayrağı — `quickReplyRow`'daki kamera düğmesiyle açılır/
    /// kapanır (bkz. ChatView). `isVoiceArmed` ile karşılıklı dışlayıcı: biri
    /// açılınca diğeri kapanır, gönder butonu ikisinden en fazla birine yönelir.
    var isImageArmed: Bool = false

    /// `showsTypingBubble`/pending state ayrımı — fotoğraf üretimi beklenirken
    /// normal "yazıyor" balonuyla AYNI görünmesin diye (bkz. ChatView.messagesList).
    var isSendingImageReply: Bool = false
```

- [ ] **Step 2: Add `sendImageRequest()`**

Add directly after `sendVoiceRequest()` (after `ChatViewModel.swift:308`, before the `applyPostReplyEffects` comment block):

```swift
    /// `send()`'in fotoğraf-isteği karşılığı: kullanıcının yazdığı tarif metninden
    /// xAI ile gerçek bir fotoğraf üretir, sonra isteğe bağlı bir metin tepkisi
    /// ister (bkz. chat/index.ts IMAGE_CAPTION_RULE — model tepki vermek istemezse
    /// [[no_caption]] döner, o zaman ikinci balon hiç eklenmez).
    func sendImageRequest() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, !isLoadingHistory else { return }

        let lastMessageAt = messages.last?.createdAt
        messages.append(Message(role: .user, content: text))
        updateCache()
        NotificationScheduler.shared.noteUserSent(character: character)
        inputText = ""
        isImageArmed = false
        isSending = true
        errorMessage = nil

        Task {
            try? await Task.sleep(nanoseconds: UInt64(TypingTiming.randomStartDelay() * 1_000_000_000))
            showsTypingBubble = true
            isSendingImageReply = true
            store?.setTyping(character.id, true)

            do {
                let stored = LocalConversationStore.shared.load(for: character.id)
                let photoURL = try await service.generateChatImage(character: character, prompt: text)

                showsTypingBubble = false
                isSendingImageReply = false
                messages.append(Message(role: .assistant, content: "", imageURL: photoURL))

                // İsteğe bağlı metin tepkisi — sırayla, fotoğraftan SONRA gelir.
                showsTypingBubble = true
                let bubbleStartedAt = Date()
                let realMsgs = realMessages()
                let result = try await service.sendWithLocalHistory(
                    character: character,
                    localMessages: realMsgs,
                    summary: stored?.summary ?? "",
                    userMessage: text,
                    level: relationshipLevel,
                    lastMessageAt: lastMessageAt,
                    imageReactionChat: true
                )

                let elapsed = Date().timeIntervalSince(bubbleStartedAt)
                let wanted = TypingTiming.duration(forReplyLength: result.reply.count)
                let remaining = wanted - elapsed
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                showsTypingBubble = false
                store?.setTyping(character.id, false)

                let caption = result.reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if caption != "[[no_caption]]" && !caption.isEmpty {
                    messages.append(Message(role: .assistant, content: caption))
                }

                applyPostReplyEffects(gotPhoto: photoURL, stored: stored)
            } catch {
                errorMessage = error.localizedDescription
                showsTypingBubble = false
                isSendingImageReply = false
                store?.setTyping(character.id, false)
            }
            isSending = false
        }
    }
```

- [ ] **Step 3: Enforce mutual exclusion between voice/image arming**

This is enforced at the call site in `ChatView` (Task 6), not inside the view model — `ChatViewModel` doesn't need a `didSet` observer since only two buttons ever toggle these two properties and both live in the same view. Confirm by grep that no other file sets `isVoiceArmed` or `isImageArmed`:

```bash
grep -rn "isVoiceArmed = \|isImageArmed = " /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend
```
Expected: only the two toggle sites you'll add in `ChatView.swift` in Task 6 (plus `sendVoiceRequest()`'s/`sendImageRequest()`'s own `= false` resets you just added/have).

- [ ] **Step 4: Standalone logic check for the caption marker (no Xcode available)**

Write a throwaway Swift script to confirm the trim-and-compare logic behaves as intended for the three cases the design relies on:

```bash
cat > /tmp/caption_check.swift << 'EOF'
func shouldShowCaption(_ reply: String) -> Bool {
    let caption = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    return caption != "[[no_caption]]" && !caption.isEmpty
}
assert(shouldShowCaption("  [[no_caption]]  ") == false)
assert(shouldShowCaption("Here you go 😘") == true)
assert(shouldShowCaption("") == false)
print("all caption-marker checks passed")
EOF
swift /tmp/caption_check.swift
```
Expected: `all caption-marker checks passed`.

- [ ] **Step 5: Commit**

```bash
git add aiGirlfriend/ViewModels/ChatViewModel.swift
git commit -m "feat: add sendImageRequest to ChatViewModel"
```

---

### Task 6: `ChatView.swift` — mode-button row, pending indicator, send routing

**Files:**
- Modify: `aiGirlfriend/Views/ChatView.swift`

**Interfaces:**
- Consumes: `ChatViewModel.isImageArmed`, `isSendingImageReply`, `sendImageRequest()` from Task 5.
- Produces: nothing consumed by later tasks (UI leaf).

- [ ] **Step 1: Delete the `quickReplies` array**

Remove (`ChatView.swift:33-38`):
```swift
    private let quickReplies = [
        String(localized: "Hey 👋"),
        String(localized: "What's up? 💕"),
        String(localized: "I missed you"),
        String(localized: "What did you do today?")
    ]
```

- [ ] **Step 2: Rewrite `quickReplyRow`**

Replace the entire `quickReplyRow` computed property (`ChatView.swift:331-366`):

```swift
    // MARK: Mod düğmeleri

    private var quickReplyRow: some View {
        HStack(spacing: 10) {
            modeButton(
                icon: viewModel.isVoiceArmed ? "waveform.circle.fill" : "waveform.circle",
                label: String(localized: "Send me a voice"),
                isArmed: viewModel.isVoiceArmed
            ) {
                viewModel.isVoiceArmed.toggle()
                if viewModel.isVoiceArmed { viewModel.isImageArmed = false }
            }

            modeButton(
                icon: viewModel.isImageArmed ? "camera.circle.fill" : "camera.circle",
                label: String(localized: "Send me a photo"),
                isArmed: viewModel.isImageArmed
            ) {
                viewModel.isImageArmed.toggle()
                if viewModel.isImageArmed { viewModel.isVoiceArmed = false }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(AppColor.card.opacity(0.6))
    }

    private func modeButton(icon: String, label: String, isArmed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18))
                Text(label).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isArmed ? AppColor.pink : .white.opacity(0.85))
            .padding(.horizontal, 14).frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(isArmed ? AppColor.pink.opacity(0.15) : .white.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(isArmed ? AppColor.pink.opacity(0.5) : .white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isSending || viewModel.isLoadingHistory)
    }
```

- [ ] **Step 3: Update the input placeholder**

Locate the `TextField` in `inputBar` (`ChatView.swift:375-377`):
```swift
                TextField("", text: $viewModel.inputText,
                          prompt: Text("Message…").foregroundColor(.white.opacity(0.4)),
                          axis: .vertical)
```
Replace with:
```swift
                TextField("", text: $viewModel.inputText,
                          prompt: Text(viewModel.isImageArmed ? "Describe the photo…" : "Message…")
                            .foregroundColor(.white.opacity(0.4)),
                          axis: .vertical)
```

- [ ] **Step 4: Update the send button's routing**

Locate (`ChatView.swift:397-399`):
```swift
            Button {
                if viewModel.isVoiceArmed { viewModel.sendVoiceRequest() } else { viewModel.send() }
            } label: {
```
Replace the button action with:
```swift
            Button {
                if viewModel.isImageArmed {
                    viewModel.sendImageRequest()
                } else if viewModel.isVoiceArmed {
                    viewModel.sendVoiceRequest()
                } else {
                    viewModel.send()
                }
            } label: {
```

- [ ] **Step 5: Add the pending-image indicator**

Locate the typing-bubble branch in `messagesList` (`ChatView.swift:295-302`):
```swift
                    if viewModel.showsTypingBubble {
                        Group {
                            if viewModel.isSendingVoiceReply {
                                VoicePendingIndicator()
                            } else {
                                TypingIndicator()
                            }
                        }
```
Replace with:
```swift
                    if viewModel.showsTypingBubble {
                        Group {
                            if viewModel.isSendingImageReply {
                                ImagePendingIndicator()
                            } else if viewModel.isSendingVoiceReply {
                                VoicePendingIndicator()
                            } else {
                                TypingIndicator()
                            }
                        }
```

- [ ] **Step 6: Add the `ImagePendingIndicator` private struct**

Read the existing `VoicePendingIndicator` struct first to match its exact visual pattern:

```bash
sed -n '539,575p' /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend/Views/ChatView.swift
```

Add a new private struct directly after `VoicePendingIndicator`'s closing brace, following the same pulsing-capsule pattern but with a camera glyph and a distinct label so it doesn't read as an audio waveform:

```swift
private struct ImagePendingIndicator: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.fill")
                .font(.system(size: 14))
                .foregroundStyle(AppColor.pink)
                .opacity(pulse ? 1 : 0.4)
            Text("Generating photo…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 14).frame(height: 34)
        .background(AppColor.card, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
```

- [ ] **Step 7: Manual review pass (no Xcode in this sandbox)**

Re-read the full edited `quickReplyRow`, `inputBar`, and `messagesList` sections and confirm:
- `AppColor.pink`/`AppColor.card` are the correct existing theme tokens (grep `AppColor.pink` elsewhere in the file to confirm spelling/usage matches).
- No leftover reference to the deleted `quickReplies` array anywhere in the file.

```bash
grep -n "quickReplies" /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend/Views/ChatView.swift
```
Expected: no matches.

- [ ] **Step 8: Commit**

```bash
git add aiGirlfriend/Views/ChatView.swift
git commit -m "feat: replace quick-reply chips with voice/photo mode buttons"
```

- [ ] **Step 9: End-to-end manual test (requires a real device/simulator build — flag as owed if unavailable)**

If Xcode is available: run the app, open a chat, tap "Send me a photo", type a description (e.g. "a selfie at the beach"), send. Confirm: (a) user message appears, (b) `ImagePendingIndicator` shows while waiting, (c) a real generated photo appears (not from the static pool — compare against `character.chatPhotos` URLs to confirm it's a new `generated/` Storage URL), (d) sometimes a caption bubble follows afterward, sometimes not. Then tap "Send me a photo" then "Send me a voice" and confirm only one stays highlighted. If Xcode is unavailable in this environment, note this step as owed in project memory (mirrors the existing pattern for prior unverified features — see `next_steps.md`).

---

### Task 7: `GeneratedPhotoService.swift` — fetch private photos

**Files:**
- Create: `aiGirlfriend/Services/GeneratedPhotoService.swift`

**Interfaces:**
- Consumes: `generated_photos` table from Task 1 (`character_id`, `url`, RLS-scoped to `user_id = auth.uid()`).
- Produces: `GeneratedPhotoService.fetch(characterId: UUID) async throws -> [URL]`, consumed by `GalleryView` in Task 8.

- [ ] **Step 1: Write the service**

```swift
//
//  GeneratedPhotoService.swift
//  Kullanıcının bir karakterle sohbette ürettiği ÖZEL fotoğrafları çeker.
//  `generated_photos` tablosu RLS ile auth.uid()'e göre filtrelenir — bu
//  yüzden anon key ile çağrılırsa boş döner, gerçek kullanıcı JWT'si gerekir.
//

import Foundation

struct GeneratedPhotoService {
    func fetch(characterId: UUID) async throws -> [URL] {
        guard let accessToken = UserDefaultsManager.shared.accessToken else { return [] }

        let endpoint = "\(Config.supabaseURL)/rest/v1/generated_photos" +
            "?select=url,created_at&character_id=eq.\(characterId.uuidString.lowercased())" +
            "&order=created_at.desc"
        guard let url = URL(string: endpoint) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "GeneratedPhotoService", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't fetch generated photos (HTTP \(code))"])
        }
        struct Row: Decodable { let url: String }
        let rows = try JSONDecoder().decode([Row].self, from: data)
        return rows.compactMap { URL(string: $0.url) }
    }
}
```

- [ ] **Step 2: Standalone verification (no Xcode — direct REST call)**

This can't be tested without a signed-in user's real JWT (anon key returns empty by design due to RLS). Confirm instead that the endpoint shape is well-formed by hitting it with the anon key and confirming it returns an empty array rather than an error (proves the RLS policy from Task 1 is active and the query syntax is valid):

```bash
curl -s "https://ohpvhgwjmrfjclnumgnm.supabase.co/rest/v1/generated_photos?select=url,created_at&character_id=eq.00000000-0000-0000-0000-000000000000&order=created_at.desc" \
  -H "apikey: sb_publishable_AdvrSU0EhHDJyWsOtGGhZg_DHca3OaB" \
  -H "Authorization: Bearer sb_publishable_AdvrSU0EhHDJyWsOtGGhZg_DHca3OaB"
```
Expected: `[]` (empty array, HTTP 200) — confirms the table/columns exist and RLS returns zero rows for a non-owning caller, not a 400/404.

- [ ] **Step 3: Commit**

```bash
git add aiGirlfriend/Services/GeneratedPhotoService.swift
git commit -m "feat: add GeneratedPhotoService for private per-user chat photos"
```

---

### Task 8: `GalleryView.swift` — "Your Photos" section

**Files:**
- Modify: `aiGirlfriend/Views/GalleryView.swift`

**Interfaces:**
- Consumes: `GeneratedPhotoService.fetch(characterId:)` from Task 7.
- Produces: nothing consumed by later tasks (UI leaf, last task in this plan).

- [ ] **Step 1: Add state and loading**

`GalleryView` is currently a stateless `View` (all computed properties, no `@State` besides `showPaywall`). Add:

```swift
struct GalleryView: View {
    let character: Character
    @Environment(\.dismiss) private var dismiss
    @State private var showPaywall = false
    @State private var yourPhotos: [URL] = []
```

Add a `.task` modifier to the existing `ZStack` in `body` (`GalleryView.swift:27`), directly after the existing `.sheet` modifier at the end of `body`:
```swift
        .sheet(isPresented: $showPaywall) { PaywallHostView() }
        .task {
            yourPhotos = (try? await GeneratedPhotoService().fetch(characterId: character.id)) ?? []
        }
```

- [ ] **Step 2: Add the "Your Photos" section view**

Add a new computed property directly after `heroCard` (before `// MARK: Kilitli foto grid`):

```swift
    // MARK: Senin Fotoğrafların

    @ViewBuilder
    private var yourPhotosSection: some View {
        if !yourPhotos.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15))
                        .foregroundStyle(AppColor.pink)
                    Text("Your Photos")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(yourPhotos.count) photos")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }

                LazyVGrid(columns: columns, spacing: 13) {
                    ForEach(yourPhotos, id: \.self) { url in
                        CachedImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            AppColor.card
                        }
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }
        }
    }
```

- [ ] **Step 3: Insert the section into the layout**

Locate the `ScrollView`'s `VStack` in `body` (`GalleryView.swift:33-36`):
```swift
            ScrollView {
                VStack(spacing: 24) {
                    heroCard
                    section
                }
```
Replace with:
```swift
            ScrollView {
                VStack(spacing: 24) {
                    heroCard
                    yourPhotosSection
                    section
                }
```

- [ ] **Step 4: Manual review pass (no Xcode in this sandbox)**

Re-read the full edited `GalleryView.swift` and confirm `columns` (used by both `yourPhotosSection` and the existing `section`) is still declared once as a shared `private let columns` and both grids reference the same instance — no duplicate declaration introduced.

```bash
grep -n "private let columns" /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend/Views/GalleryView.swift
```
Expected: exactly 1 match.

- [ ] **Step 5: Commit**

```bash
git add aiGirlfriend/Views/GalleryView.swift
git commit -m "feat: add unlocked Your Photos section to GalleryView"
```

- [ ] **Step 6: End-to-end manual test (requires a real device/simulator build — flag as owed if unavailable)**

If Xcode is available: after completing Task 6's manual test (generating at least one photo), open that character's Gallery (via Chat gear menu → Profili Görüntüle → Galeri, or the Feed card's Galeri button). Confirm the generated photo appears unblurred in a new "Your Photos" section above the existing locked/blurred grid, and that switching to a different character's Gallery does NOT show that photo (privacy/character-scoping check). If Xcode is unavailable, note this step as owed alongside Task 6's.

---

## Post-plan cleanup

After all 8 tasks are committed, update project memory (`architecture_swift.md`, `architecture_edge_functions.md`, `architecture_db.md`, `project_changelog.md`) with the new files/table/flag introduced here, following this repo's existing memory-maintenance convention — do this as a normal follow-up conversation turn, not a plan task, since memory updates aren't code changes.
