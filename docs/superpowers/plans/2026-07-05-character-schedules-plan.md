# Character Daily Schedules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each (user, character) conversation a personalized daily schedule (weekday/weekend time blocks) that shapes reply tone/availability and drives a live "At work"/"Commuting home" status line in the chat header, evolving from facts established in that specific conversation.

**Architecture:** A new edge function generates the initial schedule from the character's `system_prompt` alone; the existing 20-message summarization call is extended to also return an updated schedule. The schedule is cached client-side in `LocalConversationStore` (this app is local-first — no new server table). The client computes "what is she doing right now" purely locally (schedule + current time + weekday/weekend), no network call needed for that lookup, and sends the resulting short description on every chat turn so the server can weave it into tone.

**Tech Stack:** Supabase Edge Functions (Deno + TypeScript), xAI Grok (`grok-4-1-fast-non-reasoning`), SwiftUI, `@Observable`.

## Global Constraints

- No test framework in this repo — verify via `curl` against deployed functions and standalone `swift`/`deno run` scripts, per this project's established pattern.
- Never write the Supabase Management PAT or service-role key into any committed file — use them directly in shell commands only.
- Time is anchored to the user's device timezone (`tzOffsetMinutes`, already sent on every chat request) — no per-character geography.
- Schedule is per-(user, character) conversation, never shared across users of the same catalog character.
- No new server-side DB table — schedule lives in `LocalConversationStore.Stored` only.
- Do not commit or push unless the user explicitly asks — stage and commit each task, stop there.
- `SUPABASE_ACCESS_TOKEN=<PAT> npx supabase functions deploy <name> --project-ref ohpvhgwjmrfjclnumgnm --no-verify-jwt` must be run from `/Users/furkanozsoy/Desktop/Projects/aigf/WECAN` (deploy fails silently-wrong-directory otherwise).

---

### Task 1: `CharacterSchedule` model + `ScheduleLookup`

**Files:**
- Create: `aiGirlfriend/Models/CharacterSchedule.swift`
- Create: `aiGirlfriend/Services/ScheduleLookup.swift`

**Interfaces:**
- Produces: `struct ScheduleBlock: Codable, Equatable { let start, end, label, detail: String }`, `struct CharacterSchedule: Codable, Equatable { let weekday, weekend: [ScheduleBlock] }`, `ScheduleLookup.currentBlock(schedule: CharacterSchedule, date: Date = Date(), calendar: Calendar = .current) -> ScheduleBlock?` — every later task depends on these exact names/signatures.

- [ ] **Step 1: Write the model**

```swift
//
//  CharacterSchedule.swift
//  Bir (kullanıcı, karakter) sohbetine özel günlük rutin — mesleğe/kişiliğe
//  göre üretilir, sohbetteki gerçeklere göre zamanla güncellenir (bkz.
//  ChatViewModel.ensureScheduleGenerated / triggerSummarizationIfNeeded).
//

import Foundation

struct ScheduleBlock: Codable, Equatable {
    /// "HH:mm", 24 saat, cihazın yerel saatine göre. `end < start` ise gece
    /// yarısını geçen bir blok demektir (ör. start "23:00", end "07:00").
    let start: String
    let end: String
    /// Kısa, chat header'da gösterilecek — "At work".
    let label: String
    /// Daha ayrıntılı, sistem promptuna eklenecek — "at work in the lab
    /// running experiments".
    let detail: String
}

struct CharacterSchedule: Codable, Equatable {
    let weekday: [ScheduleBlock]
    let weekend: [ScheduleBlock]
}
```

- [ ] **Step 2: Write `ScheduleLookup`**

```swift
//
//  ScheduleLookup.swift
//  Verilen bir CharacterSchedule ve zamana göre "şu an ne yapıyor" bloğunu
//  bulur — saf/durumsuz, ağ çağrısı yok, her ChatView render'ında ucuza
//  çağrılabilir.
//

import Foundation

enum ScheduleLookup {
    static func currentBlock(
        schedule: CharacterSchedule,
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> ScheduleBlock? {
        let blocks = calendar.isDateInWeekend(date) ? schedule.weekend : schedule.weekday
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = comps.hour, let minute = comps.minute else { return nil }
        let nowMinutes = hour * 60 + minute

        for block in blocks {
            guard let startMinutes = minutesFromHHmm(block.start),
                  let endMinutes = minutesFromHHmm(block.end) else { continue }
            if startMinutes <= endMinutes {
                if nowMinutes >= startMinutes && nowMinutes < endMinutes { return block }
            } else {
                // Gece yarısını geçen blok (ör. 23:00-07:00).
                if nowMinutes >= startMinutes || nowMinutes < endMinutes { return block }
            }
        }
        return nil
    }

    private static func minutesFromHHmm(_ s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
}
```

- [ ] **Step 3: Standalone verification (no Xcode in this sandbox)**

```bash
cat > /tmp/schedule_check.swift << 'EOF'
import Foundation

struct ScheduleBlock: Codable, Equatable {
    let start: String
    let end: String
    let label: String
    let detail: String
}
struct CharacterSchedule: Codable, Equatable {
    let weekday: [ScheduleBlock]
    let weekend: [ScheduleBlock]
}

enum ScheduleLookup {
    static func currentBlock(schedule: CharacterSchedule, date: Date = Date(), calendar: Calendar = .current) -> ScheduleBlock? {
        let blocks = calendar.isDateInWeekend(date) ? schedule.weekend : schedule.weekday
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = comps.hour, let minute = comps.minute else { return nil }
        let nowMinutes = hour * 60 + minute
        for block in blocks {
            guard let startMinutes = minutesFromHHmm(block.start), let endMinutes = minutesFromHHmm(block.end) else { continue }
            if startMinutes <= endMinutes {
                if nowMinutes >= startMinutes && nowMinutes < endMinutes { return block }
            } else {
                if nowMinutes >= startMinutes || nowMinutes < endMinutes { return block }
            }
        }
        return nil
    }
    private static func minutesFromHHmm(_ s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
}

let schedule = CharacterSchedule(
    weekday: [
        ScheduleBlock(start: "07:00", end: "09:00", label: "Getting ready", detail: "getting ready, having coffee"),
        ScheduleBlock(start: "09:00", end: "17:00", label: "At work", detail: "at work in the lab"),
        ScheduleBlock(start: "17:00", end: "23:00", label: "At home", detail: "relaxing at home"),
        ScheduleBlock(start: "23:00", end: "07:00", label: "Asleep", detail: "sleeping"),
    ],
    weekend: [
        ScheduleBlock(start: "00:00", end: "23:59", label: "Free day", detail: "enjoying a day off"),
    ]
)

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "UTC")!

func at(_ h: Int, _ m: Int, weekday: Int) -> Date {
    var comps = DateComponents()
    comps.year = 2026; comps.month = 7; comps.day = weekday == 2 ? 6 : 4 // 2026-07-06 is a Monday, 2026-07-04 a Saturday
    comps.hour = h; comps.minute = m
    return cal.date(from: comps)!
}

let noon = at(12, 0, weekday: 2)
assert(ScheduleLookup.currentBlock(schedule: schedule, date: noon, calendar: cal)?.label == "At work", "expected At work at noon on a weekday")

let midnight = at(2, 0, weekday: 2)
assert(ScheduleLookup.currentBlock(schedule: schedule, date: midnight, calendar: cal)?.label == "Asleep", "expected Asleep for overnight-wrapping block")

let saturday = at(12, 0, weekday: 1)
assert(ScheduleLookup.currentBlock(schedule: schedule, date: saturday, calendar: cal)?.label == "Free day", "expected weekend block on Saturday")

print("all schedule lookup checks passed")
EOF
swift /tmp/schedule_check.swift
rm /tmp/schedule_check.swift
```
Expected: `all schedule lookup checks passed`.

- [ ] **Step 4: Commit**

```bash
cd /Users/furkanozsoy/Desktop/Projects/aigf/WECAN
git add aiGirlfriend/Models/CharacterSchedule.swift aiGirlfriend/Services/ScheduleLookup.swift
git commit -m "feat: add CharacterSchedule model and ScheduleLookup"
```

---

### Task 2: `character-schedule` edge function (initial generation)

**Files:**
- Create: `supabase/functions/character-schedule/index.ts`

**Interfaces:**
- Produces: `POST /functions/v1/character-schedule` — Request `{ characterId: string, systemPrompt: string }` with `Authorization: Bearer <JWT>`. Response `{ schedule: { weekday: [...], weekend: [...] } }` (200) or `{ error: string }` (401/400/502) — same JSON shape as `CharacterSchedule` from Task 1 (`weekday`/`weekend` arrays of `{start, end, label, detail}`).

- [ ] **Step 1: Write the edge function**

```typescript
// supabase/functions/character-schedule/index.ts
//
// Karakterin system_prompt'undan (kişilik/meslek/vibe zaten içinde) günlük
// bir rutin (hafta içi + hafta sonu) üretir — ilk sohbet açıldığında,
// henüz hiç mesaj yokken çağrılır (bkz. ChatViewModel.ensureScheduleGenerated).
// Sonraki güncellemeler chat/index.ts'nin özetleme moduna binmiş şekilde olur.
//
//   İstek:  { characterId, systemPrompt }  (Authorization: Bearer <JWT> zorunlu)
//   Cevap:  { schedule: { weekday: [...], weekend: [...] } }  veya  { error }

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const XAI_API_KEY = Deno.env.get("XAI_API_KEY") ?? "";
const XAI_URL = "https://api.x.ai/v1/chat/completions";
const MODEL = "grok-4-1-fast-non-reasoning";

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

const SCHEDULE_PROMPT_INSTRUCTIONS =
  "Bu karakter için gerçekçi bir günlük rutin (hafta içi + hafta sonu) " +
  "üret. Kişiliğine ve mesleğine uygun, somut zaman blokları yaz — uyku " +
  "dahil GÜNÜN TAMAMINI boşluksuz kapla. Hafta sonu hafta içinden FARKLI " +
  "olmalı (çoğu meslek 7 gün çalışmaz). " +
  "SADECE şu JSON şemasında cevap ver, başka hiçbir şey yazma (markdown " +
  "kod bloğu da yok):\n" +
  '{"weekday":[{"start":"HH:mm","end":"HH:mm","label":"kısa İngilizce ' +
  'etiket","detail":"daha ayrıntılı İngilizce açıklama"}],"weekend":[...]}';

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);

    const b = await req.json();
    const characterId: string = b.characterId;
    const systemPrompt: string = (b.systemPrompt ?? "").toString().trim();
    if (!characterId) return json({ error: "characterId required" }, 400);
    if (!systemPrompt) return json({ error: "systemPrompt required" }, 400);

    const resp = await fetch(XAI_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${XAI_API_KEY}` },
      body: JSON.stringify({
        model: MODEL,
        messages: [
          { role: "system", content: `${systemPrompt}\n\n${SCHEDULE_PROMPT_INSTRUCTIONS}` },
          { role: "user", content: "Generate the schedule JSON now." },
        ],
        temperature: 0.8,
        max_tokens: 900,
      }),
    });
    if (!resp.ok) return json({ error: `LLM ${resp.status}: ${await resp.text()}` }, 502);
    const data = await resp.json();
    const raw: string = data?.choices?.[0]?.message?.content ?? "";
    const match = raw.match(/\{[\s\S]*\}/);
    if (!match) return json({ error: "no_json_in_response" }, 502);

    const parsed = JSON.parse(match[0]);
    if (!Array.isArray(parsed.weekday) || !Array.isArray(parsed.weekend)) {
      return json({ error: "invalid_schedule_shape" }, 502);
    }

    return json({ schedule: { weekday: parsed.weekday, weekend: parsed.weekend } });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
```

- [ ] **Step 2: Deploy**

```bash
cd /Users/furkanozsoy/Desktop/Projects/aigf/WECAN
SUPABASE_ACCESS_TOKEN=<PAT from project memory> npx supabase functions deploy character-schedule --project-ref ohpvhgwjmrfjclnumgnm --no-verify-jwt
```
Expected: `Deployed Functions.`

- [ ] **Step 3: Verify auth gate**

```bash
curl -s -X POST "https://ohpvhgwjmrfjclnumgnm.supabase.co/functions/v1/character-schedule" \
  -H "Content-Type: application/json" \
  -d '{"characterId":"x","systemPrompt":"You are Aria, a scientist."}'
```
Expected: `{"error":"unauthorized"}`.

- [ ] **Step 4: Verify with a real (cheap, text-only) call**

Get a fresh anonymous JWT (no cost — auth signup, not an LLM call):
```bash
curl -s -X POST "https://ohpvhgwjmrfjclnumgnm.supabase.co/auth/v1/signup" \
  -H "apikey: sb_publishable_AdvrSU0EhHDJyWsOtGGhZg_DHca3OaB" \
  -H "Content-Type: application/json" -d '{}' | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
```
Then (substitute `$TOKEN` with that value):
```bash
curl -s -X POST "https://ohpvhgwjmrfjclnumgnm.supabase.co/functions/v1/character-schedule" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: sb_publishable_AdvrSU0EhHDJyWsOtGGhZg_DHca3OaB" \
  -d '{"characterId":"00000000-0000-0000-0000-000000000002","systemPrompt":"You are Aria, a 24-year-old research scientist who works in a molecular biology lab. Warm, flirty, curious."}' \
  --max-time 60 | python3 -m json.tool
```
Expected: `{"schedule": {"weekday": [...], "weekend": [...]}}` with plausible lab-scientist blocks covering all 24 hours on both arrays, no `error` key.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/character-schedule/index.ts
git commit -m "feat: add character-schedule edge function for initial schedule generation"
```

---

### Task 3: `chat/index.ts` — currentActivity injection + schedule refinement

**Files:**
- Modify: `supabase/functions/chat/index.ts`

**Interfaces:**
- Consumes: `CharacterSchedule` JSON shape from Task 1/2 (`{weekday, weekend}` arrays of `{start,end,label,detail}`).
- Produces: request field `currentActivity: string | undefined` (normal reply mode) — instruction appended to system prompt when present. Summarize-mode request gains `previousSchedule: CharacterSchedule | null | undefined`; its response shape changes from `{ summary }` to `{ summary, schedule }` where `schedule` is `CharacterSchedule | null` (null if generation/parsing failed, in which case the caller should keep its previous schedule). `ChatService.generateLocalSummary` (Task 5) depends on this exact response shape.

- [ ] **Step 1: Add the JSON-extraction helper (shared with the summarize rewrite)**

Add near the top of the file, after the existing `interface WireMessage` line:

```typescript
// Grok bazen JSON'un etrafına markdown kod bloğu veya açıklama ekliyor —
// create-character/index.ts'deki aynı savunma amaçlı ayıklama deseni.
function extractJson(raw: string): any | null {
  const match = raw.match(/\{[\s\S]*\}/);
  if (!match) return null;
  try { return JSON.parse(match[0]); } catch { return null; }
}
```

- [ ] **Step 2: Read `currentActivity` from the request body**

Locate `const imageReactionChat: boolean = body.imageReactionChat === true;` and add directly below it:

```typescript
    // Günlük rutin (bkz. character-schedule fonksiyonu) — istemci "şu an ne
    // yapıyor" bloğunun `detail` metnini gönderir, burada tona yansıtılır.
    const currentActivity: string | undefined =
      typeof body.currentActivity === "string" && body.currentActivity.trim()
        ? body.currentActivity.trim()
        : undefined;
```

- [ ] **Step 3: Inject the instruction into the system prompt**

Locate the `MEDIA_REQUEST_RULE` block:
```typescript
    if (!voiceChat && !imageReactionChat) {
      system += MEDIA_REQUEST_RULE;
    }
```
Add directly after it:

```typescript
    if (currentActivity) {
      system += `\n\n[GÜNLÜK RUTİN] Şu anda: ${currentActivity}. Ton ve ` +
        `müsaitliğini buna doğal şekilde yansıt (ör. işteyken kısa/dikkati ` +
        `dağınık, evde rahatken daha uzun sohbet edebilirsin) ama bunu her ` +
        `mesajda birebir tekrarlama.`;
    }
```

- [ ] **Step 4: Rewrite the client-side-summarize branch to also produce a schedule**

Replace the entire `if (Array.isArray(body.summarizeMessages) ...)` block:

```typescript
    // === İSTEMCİ TARAFLI ÖZETLEME MODU ===
    // Kullanıcı karakterleri her 20 mesajda bir bunu tetikler. Aynı çağrıda
    // günlük rutini de gözden geçirir (bkz. character-schedule — bu SADECE
    // rafine eder, ilk üretim orada olur).
    if (Array.isArray(body.summarizeMessages) && body.summarizeMessages.length > 0) {
      const convoText = (body.summarizeMessages as WireMessage[])
        .map((m) => `${m.role === "user" ? "Kullanıcı" : "Sen"}: ${stripVoiceTags(m.content)}`)
        .join("\n");
      const previousSchedule = body.previousSchedule ?? null;
      const summaryPrompt: WireMessage[] = [
        {
          role: "system",
          content:
            "Bir sohbet özetini ve karakterin günlük rutinini güncelliyorsun. " +
            "Karakterin İLERİDE hatırlaması gereken kalıcı bilgileri özete " +
            "çıkar — hem KULLANICI hakkında (adı, tercihleri, ilişki durumu/ " +
            "önemli anlar, söz verilen şeyler) HEM DE KARAKTERİN KENDİSİ " +
            "hakkında kendi söylediği kalıcı gerçekler (mesleği, iş yeri, " +
            "ailesi, geçmişi, hobileri). Karakter kendi hakkında bir şey " +
            "söylediyse (ör. \"laboratuvarda çalışıyorum\") bunu MUTLAKA " +
            "özete ekle. Ayrıca mevcut günlük rutini gözden geçir: yeni " +
            "konuşmada rutinini değiştiren bir gerçek varsa (ör. işten " +
            "ayrıldı, gece vardiyasına geçti) rutini buna göre güncelle; " +
            "yoksa MEVCUT rutini olduğu gibi koru (uydurma, değiştirme). " +
            "SADECE şu JSON şemasında cevap ver, başka hiçbir şey yazma: " +
            '{"summary":"kısa madde madde, önceki özeti koruyup yenileri ' +
            'ekleyerek","schedule":{"weekday":[{"start":"HH:mm","end":"HH:mm",' +
            '"label":"...","detail":"..."}],"weekend":[...]}}',
        },
        {
          role: "user",
          content:
            `Önceki özet:\n${body.existingSummary ? stripVoiceTags(body.existingSummary) : "(yok)"}\n\n` +
            `Mevcut günlük rutin:\n${previousSchedule ? JSON.stringify(previousSchedule) : "(henüz yok)"}\n\n` +
            `Yeni konuşma:\n${convoText}\n\nGüncellenmiş JSON:`,
        },
      ];
      const raw = await callGrok(summaryPrompt, 900);
      const parsed = extractJson(raw);
      const summary: string = typeof parsed?.summary === "string" ? parsed.summary : raw.trim();
      const schedule = (parsed && Array.isArray(parsed.schedule?.weekday) && Array.isArray(parsed.schedule?.weekend))
        ? parsed.schedule
        : null;
      return json({ summary, schedule });
    }
```

- [ ] **Step 5: Apply the same voice-tag stripping + JSON helper to the legacy DB-mode summarize branch for consistency**

Locate the second (DB-mode, legacy) summarize block further down (search for `toFold`) and change its `convoText` line the same way Task-3-relevant stripping was already applied elsewhere:

```typescript
        const convoText = toFold
          .map((m) => `${m.role === "user" ? "Kullanıcı" : "Sen"}: ${stripVoiceTags(m.content)}`)
          .join("\n");
```
(This block stays summary-only, no schedule — it's the pre-local-first legacy path used only for first-ever migration reads, not worth extending further per YAGNI.)

- [ ] **Step 6: Deploy**

```bash
cd /Users/furkanozsoy/Desktop/Projects/aigf/WECAN
SUPABASE_ACCESS_TOKEN=<PAT> npx supabase functions deploy chat --project-ref ohpvhgwjmrfjclnumgnm --no-verify-jwt
```
Expected: `Deployed Functions.`

- [ ] **Step 7: Verify auth gate untouched**

```bash
curl -s -X POST "https://ohpvhgwjmrfjclnumgnm.supabase.co/functions/v1/chat" -H "Content-Type: application/json" -d '{"characterId":"x"}'
```
Expected: `{"error":"unauthorized"}`.

- [ ] **Step 8: Verify the summarize+schedule combined call with a real JWT**

Reuse the `$TOKEN` from Task 2 Step 4 (or mint a fresh one the same way):
```bash
curl -s -X POST "https://ohpvhgwjmrfjclnumgnm.supabase.co/functions/v1/chat" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: sb_publishable_AdvrSU0EhHDJyWsOtGGhZg_DHca3OaB" \
  -d '{
    "characterId":"00000000-0000-0000-0000-000000000002",
    "systemPrompt":"You are Aria, a research scientist in a lab.",
    "existingSummary": "",
    "previousSchedule": {"weekday":[{"start":"09:00","end":"17:00","label":"At work","detail":"at the lab"}],"weekend":[{"start":"00:00","end":"23:59","label":"Free day","detail":"day off"}]},
    "summarizeMessages": [
      {"role":"user","content":"hows work"},
      {"role":"assistant","content":"actually I just quit! starting a bakery instead, I open at 5am now"}
    ]
  }' --max-time 60 | python3 -m json.tool
```
Expected: `summary` mentions quitting the lab job / starting a bakery, and `schedule.weekday` blocks now reflect an early-morning bakery routine instead of the old 09:00-17:00 lab block.

- [ ] **Step 9: Verify `currentActivity` shapes a normal reply**

```bash
curl -s -X POST "https://ohpvhgwjmrfjclnumgnm.supabase.co/functions/v1/chat" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: sb_publishable_AdvrSU0EhHDJyWsOtGGhZg_DHca3OaB" \
  -d '{
    "characterId":"00000000-0000-0000-0000-000000000002",
    "systemPrompt":"You are Aria, a research scientist in a lab.",
    "clientHistory":[],
    "userMessage":"hey whats up",
    "level":2,
    "currentActivity":"at work in the lab, mid-experiment, can only glance at her phone"
  }' --max-time 60 | python3 -m json.tool
```
Expected: `reply` reads as brief/distracted-at-work in tone (not a guaranteed exact match, but should not read like a fully relaxed at-home reply).

- [ ] **Step 10: Commit**

```bash
git add supabase/functions/chat/index.ts
git commit -m "feat: currentActivity tone shaping + schedule refinement in summarization"
```

---

### Task 4: `LocalConversationStore` — add `schedule` field

**Files:**
- Modify: `aiGirlfriend/Services/LocalConversationStore.swift`

**Interfaces:**
- Consumes: `CharacterSchedule` from Task 1.
- Produces: `LocalConversationStore.Stored.schedule: CharacterSchedule?` (mutable `var`, decodes to `nil` for pre-existing stored files). `LocalConversationStore.updateSummary(for:summary:summarizedCount:schedule:)` gains a trailing optional `schedule` parameter, default `nil` (meaning "leave existing schedule untouched").

- [ ] **Step 1: Add the field, CodingKeys case, and both initializers**

Replace the full `Stored` struct in `LocalConversationStore.swift`:

```swift
    struct Stored: Codable {
        var messages: [Message]       // tüm gerçek mesajlar (görüntüleme için)
        var xp: Int                   // eski mutlak XP alanı — artık kullanılmıyor, geriye dönük uyum için duruyor
        var level: Int
        var summary: String           // özetlenmiş eski mesajlar
        var summarizedCount: Int      // kaç mesaj özetlendi
        var msgCounter: Int = 0       // terfi eşiği için mesaj sayacı (istemci taraflı)
        var levelProgress: Double = 0 // güncel seviyenin ne kadarı tamamlandı (0...1), bkz. RelationshipXP
        /// Sohbetin GERÇEKTE hangi dilde geçtiğine dair son tahmin ("tr"/"en") —
        /// bildirim içeriği (JealousyContent vb.) bunu kullanır. Bkz. ConversationLanguage.
        var detectedLanguage: String?
        /// Bu (kullanıcı, karakter) sohbetine özel günlük rutin — bkz.
        /// CharacterSchedule, ChatViewModel.ensureScheduleGenerated. Eski
        /// kayıtlarda yok, `nil` olarak decode edilir.
        var schedule: CharacterSchedule?

        enum CodingKeys: String, CodingKey {
            case messages, xp, level, summary, summarizedCount, msgCounter, levelProgress, detectedLanguage, schedule
        }

        init(
            messages: [Message], xp: Int, level: Int, summary: String, summarizedCount: Int,
            msgCounter: Int = 0, levelProgress: Double = 0, detectedLanguage: String? = nil,
            schedule: CharacterSchedule? = nil
        ) {
            self.messages = messages
            self.xp = xp
            self.level = level
            self.summary = summary
            self.summarizedCount = summarizedCount
            self.msgCounter = msgCounter
            self.levelProgress = levelProgress
            self.detectedLanguage = detectedLanguage
            self.schedule = schedule
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            messages = try c.decode([Message].self, forKey: .messages)
            xp = try c.decode(Int.self, forKey: .xp)
            level = try c.decode(Int.self, forKey: .level)
            summary = try c.decode(String.self, forKey: .summary)
            summarizedCount = try c.decode(Int.self, forKey: .summarizedCount)
            // Eski kayıtlarda yok — 0'dan başlar (küçük bir kozmetik sıfırlama, sorun değil).
            msgCounter = (try? c.decode(Int.self, forKey: .msgCounter)) ?? 0
            levelProgress = (try? c.decode(Double.self, forKey: .levelProgress)) ?? 0
            detectedLanguage = try? c.decode(String.self, forKey: .detectedLanguage)
            schedule = try? c.decodeIfPresent(CharacterSchedule.self, forKey: .schedule)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(messages, forKey: .messages)
            try c.encode(xp, forKey: .xp)
            try c.encode(level, forKey: .level)
            try c.encode(summary, forKey: .summary)
            try c.encode(summarizedCount, forKey: .summarizedCount)
            try c.encode(msgCounter, forKey: .msgCounter)
            try c.encode(levelProgress, forKey: .levelProgress)
            try c.encodeIfPresent(detectedLanguage, forKey: .detectedLanguage)
            try c.encodeIfPresent(schedule, forKey: .schedule)
        }
    }
```

- [ ] **Step 2: Extend `updateSummary` to optionally carry a schedule update**

Replace:
```swift
    func updateSummary(for id: UUID, summary: String, summarizedCount: Int) {
        guard var stored = load(for: id) else { return }
        stored.summary = summary
        stored.summarizedCount = summarizedCount
        save(stored, for: id)
    }
```
with:
```swift
    func updateSummary(for id: UUID, summary: String, summarizedCount: Int, schedule: CharacterSchedule? = nil) {
        guard var stored = load(for: id) else { return }
        stored.summary = summary
        stored.summarizedCount = summarizedCount
        if let schedule { stored.schedule = schedule }
        save(stored, for: id)
    }
```

- [ ] **Step 3: Manual review pass (no Xcode in this sandbox)**

Confirm every other `LocalConversationStore.Stored(...)` construction site in the codebase still compiles with the new trailing defaulted `schedule` param (it's defaulted, so omitting it is fine):

```bash
grep -rn "LocalConversationStore.Stored(" /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend
```
Expected: 2 matches (`ChatViewModel.swift`'s `primeFromServer()` and `updateCache()`), neither passing `schedule:` — confirms the default keeps them compiling unchanged (they'll be updated to actually pass it in Task 6).

- [ ] **Step 4: Commit**

```bash
git add aiGirlfriend/Services/LocalConversationStore.swift
git commit -m "feat: add schedule field to LocalConversationStore.Stored"
```

---

### Task 5: `ChatService.swift` — schedule generation + threading

**Files:**
- Modify: `aiGirlfriend/Config.swift`
- Modify: `aiGirlfriend/Services/ChatService.swift`

**Interfaces:**
- Consumes: `CharacterSchedule`/`ScheduleBlock` from Task 1; `character-schedule` endpoint from Task 2; `chat`'s extended summarize response from Task 3.
- Produces: `ChatService.generateInitialSchedule(character: Character) async throws -> CharacterSchedule`. `ChatService.generateLocalSummary(character:messagesToFold:existingSummary:previousSchedule:) async throws -> (summary: String, schedule: CharacterSchedule?)` — return type changes from `String` to a tuple; `ChatViewModel` (Task 6) is updated to match. `ChatService.sendWithLocalHistory(...)` gains a `currentActivity: String? = nil` parameter, forwarded to the server.

- [ ] **Step 1: Add the function URL**

In `Config.swift`, add after `chatImageFunctionURL`:
```swift
    /// Karakterin ilk günlük rutinini üretir (bkz. ChatViewModel.ensureScheduleGenerated).
    static var characterScheduleFunctionURL: URL {
        URL(string: "\(supabaseURL)/functions/v1/character-schedule")!
    }
```

- [ ] **Step 2: Add `currentActivity`/`previousSchedule` to `ChatRequest`, `schedule` to `ChatResponse`**

In `ChatService.swift`, add to `ChatRequest` directly below `imageReactionChat`:
```swift
    let imageReactionChat: Bool?
    /// Günlük rutinden "şu an ne yapıyor" bloğunun ayrıntılı açıklaması —
    /// bkz. ChatViewModel.currentActivity, chat/index.ts GÜNLÜK RUTİN notu.
    let currentActivity: String?
    /// Özetleme modunda: istemcinin şu an bildiği rutin, sunucu bunu
    /// gözden geçirip günceller (bkz. generateLocalSummary).
    let previousSchedule: CharacterSchedule?
}
```

Add to `ChatResponse` directly below `summary`:
```swift
    let summary: String?   // özetleme modunda döner
    let schedule: CharacterSchedule?   // özetleme modunda döner (rafine edilmiş rutin)
}
```

- [ ] **Step 3: Thread `currentActivity` through `sendWithLocalHistory` → `perform`**

Replace `sendWithLocalHistory`'s signature and body:
```swift
    func sendWithLocalHistory(
        character: Character,
        localMessages: [Message],
        summary: String,
        userMessage: String,
        level: Int,
        lastMessageAt: Date? = nil,
        voiceChat: Bool = false,
        imageReactionChat: Bool = false,
        currentActivity: String? = nil
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
            imageReactionChat: imageReactionChat,
            currentActivity: currentActivity
        )
        return ChatReply(
            reply: resp.reply ?? "",
            level: resp.level ?? level,
            photoURL: resp.photoUrl.flatMap(URL.init(string:))
        )
    }
```

Update `perform`'s signature (add `currentActivity: String? = nil, previousSchedule: CharacterSchedule? = nil`) and its `ChatRequest(...)` construction:
```swift
    private func perform(
        character: Character,
        userMessage: String?,
        extra: RequestExtra = .none,
        level: Int? = nil,
        lastMessageAt: Date? = nil,
        voiceChat: Bool = false,
        imageReactionChat: Bool = false,
        currentActivity: String? = nil,
        previousSchedule: CharacterSchedule? = nil
    ) async throws -> ChatResponse {
```
and in the same function's body construction, add the two fields:
```swift
            clearConversation: clearConversation,
            voiceChat: voiceChat,
            imageReactionChat: imageReactionChat,
            currentActivity: currentActivity,
            previousSchedule: previousSchedule
        )
        request.httpBody = try JSONEncoder().encode(body)
```
(replacing the existing `clearConversation: clearConversation, voiceChat: voiceChat, imageReactionChat: imageReactionChat\n        )` closing of the `ChatRequest(...)` call.)

- [ ] **Step 4: Update `generateLocalSummary` to send/receive the schedule**

Replace:
```swift
    func generateLocalSummary(
        character: Character,
        messagesToFold: [Message],
        existingSummary: String
    ) async throws -> String {
        let wire = messagesToFold
            .filter { $0.imageURL == nil }
            .map { WireHistoryMessage(role: $0.role.rawValue, content: $0.content) }
        let resp = try await perform(
            character: character,
            userMessage: nil,
            extra: .summarize(wire, existing: existingSummary)
        )
        return resp.summary ?? existingSummary
    }
```
with:
```swift
    func generateLocalSummary(
        character: Character,
        messagesToFold: [Message],
        existingSummary: String,
        previousSchedule: CharacterSchedule?
    ) async throws -> (summary: String, schedule: CharacterSchedule?) {
        let wire = messagesToFold
            .filter { $0.imageURL == nil }
            .map { WireHistoryMessage(role: $0.role.rawValue, content: $0.content) }
        let resp = try await perform(
            character: character,
            userMessage: nil,
            extra: .summarize(wire, existing: existingSummary),
            previousSchedule: previousSchedule
        )
        return (resp.summary ?? existingSummary, resp.schedule)
    }
```

- [ ] **Step 5: Add `generateInitialSchedule`**

Add as a new method on `ChatService`, directly after `generateChatImage`:
```swift
    private struct CharacterScheduleRequest: Codable {
        let characterId: String
        let systemPrompt: String
    }

    private struct CharacterScheduleResponse: Codable {
        let schedule: CharacterSchedule?
        let error: String?
    }

    /// İlk günlük rutin üretimi — bkz. ChatViewModel.ensureScheduleGenerated,
    /// sadece cihazda hiç kayıtlı rutin yokken çağrılır.
    func generateInitialSchedule(character: Character) async throws -> CharacterSchedule {
        var request = URLRequest(url: Config.characterScheduleFunctionURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bearer = UserDefaultsManager.shared.accessToken ?? Config.supabaseAnonKey
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(
            CharacterScheduleRequest(characterId: character.id.uuidString.lowercased(), systemPrompt: character.systemPrompt)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatServiceError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw ChatServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let decoded = try? JSONDecoder().decode(CharacterScheduleResponse.self, from: data),
              let schedule = decoded.schedule else {
            throw ChatServiceError.decoding
        }
        return schedule
    }
```

- [ ] **Step 6: Manual review pass (no Xcode in this sandbox)**

Re-read the full edited `ChatService.swift` and confirm every call site of `generateLocalSummary` and `sendWithLocalHistory` will be updated in Task 6 (they will not compile as-is until then — expected, this task only prepares the service layer):
```bash
grep -n "generateLocalSummary(\|sendWithLocalHistory(" /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend/ViewModels/ChatViewModel.swift
```
Expected: `generateLocalSummary(` once (in `triggerSummarizationIfNeeded`), `sendWithLocalHistory(` three times (`send`, `sendVoiceRequest`, `sendImageRequest`) — all four call sites get updated in Task 6.

- [ ] **Step 7: Commit**

```bash
git add aiGirlfriend/Config.swift aiGirlfriend/Services/ChatService.swift
git commit -m "feat: add generateInitialSchedule, thread currentActivity/schedule through ChatService"
```

---

### Task 6: `ChatViewModel.swift` — activity tracking + threading

**Files:**
- Modify: `aiGirlfriend/ViewModels/ChatViewModel.swift`

**Interfaces:**
- Consumes: everything from Task 5 (`ChatService.generateInitialSchedule`, updated `generateLocalSummary`/`sendWithLocalHistory`), `ScheduleLookup.currentBlock` from Task 1, `LocalConversationStore.updateSummary(...:schedule:)` from Task 4.
- Produces: `ChatViewModel.currentActivity: (label: String, detail: String)?` (readable by `ChatView` in Task 7), `ChatViewModel.startActivityRefreshLoop() async` (called from `ChatView`'s `.task`).

- [ ] **Step 1: Add the `currentActivity` property**

Add directly after the existing `var isSendingImageReply: Bool = false` declaration:
```swift
    /// "Şu an ne yapıyor" — ScheduleLookup ile yerelden hesaplanır, ağ
    /// çağrısı gerektirmez. `nil` = henüz rutin üretilmedi ya da eşleşen
    /// blok yok (chat header bu durumda "Online" göstermeye devam eder).
    var currentActivity: (label: String, detail: String)?
```

- [ ] **Step 2: Add `refreshCurrentActivity`, `ensureScheduleGenerated`, and `startActivityRefreshLoop`**

Add as new methods directly after `triggerSummarizationIfNeeded()` (before `// MARK: - Yardımcılar`):
```swift
    // MARK: - Günlük rutin

    /// Cihazdaki kayıtlı rutine göre "şu an ne yapıyor" bloğunu yerelden
    /// hesaplar — ağ çağrısı yok, ucuz, her çağrıda güvenle tekrar edilebilir.
    private func refreshCurrentActivity() {
        guard let schedule = LocalConversationStore.shared.load(for: character.id)?.schedule,
              let block = ScheduleLookup.currentBlock(schedule: schedule) else {
            currentActivity = nil
            return
        }
        currentActivity = (label: block.label, detail: block.detail)
    }

    /// Cihazda hiç rutin yoksa (yeni sohbet) arka planda ilk rutini üretir.
    /// Kullanıcının ilk mesajını GECİKTİRMEZ — tamamlanmadan mesaj gönderilirse
    /// o tur sadece currentActivity bağlamı olmadan devam eder. Diğer
    /// Task.detached kullanan metotlarla (bkz. triggerSummarizationIfNeeded)
    /// aynı desen: ihtiyaç duyulan değerler ÖNCEDEN çıkarılır, `self` background
    /// task içine güçlü referansla sızmaz — sadece son UI-yenileme adımında
    /// `weak self` ile dokunulur.
    private func ensureScheduleGenerated() {
        guard LocalConversationStore.shared.load(for: character.id)?.schedule == nil else { return }
        let characterId = character.id
        let fallbackLevel = relationshipLevel
        let fallbackProgress = levelProgress
        Task.detached(priority: .background) { [service = self.service, character = self.character, weak self] in
            guard let schedule = try? await service.generateInitialSchedule(character: character) else { return }
            await MainActor.run {
                var stored = LocalConversationStore.shared.load(for: characterId) ?? LocalConversationStore.Stored(
                    messages: [], xp: 0, level: fallbackLevel, summary: "", summarizedCount: 0,
                    levelProgress: fallbackProgress
                )
                stored.schedule = schedule
                LocalConversationStore.shared.save(stored, for: characterId)
                self?.refreshCurrentActivity()
            }
        }
    }

    /// `ChatView`'in `.task` içinden çağrılır — view kaybolunca SwiftUI
    /// otomatik iptal eder, elle Timer yönetimine gerek yok.
    func startActivityRefreshLoop() async {
        while !Task.isCancelled {
            refreshCurrentActivity()
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }
```

- [ ] **Step 3: Call both on history load**

In `loadHistory()`, add `refreshCurrentActivity()` and `ensureScheduleGenerated()` at both exit points. Replace:
```swift
        if let cached = store?.chatCache[character.id], !cached.isEmpty {
            messages = cached
            hasSyntheticOpening = false
            isLoadingHistory = false
            markReadNow()
            return
        }
```
with:
```swift
        if let cached = store?.chatCache[character.id], !cached.isEmpty {
            messages = cached
            hasSyntheticOpening = false
            isLoadingHistory = false
            markReadNow()
            refreshCurrentActivity()
            ensureScheduleGenerated()
            return
        }
```
and replace the end of the function:
```swift
        isLoadingHistory = false
        markReadNow()
    }
```
with:
```swift
        isLoadingHistory = false
        markReadNow()
        refreshCurrentActivity()
        ensureScheduleGenerated()
    }
```

- [ ] **Step 4: Preserve `schedule` across every `updateCache()` write**

Locate `updateCache(msgCounter:)` and add `schedule: stored?.schedule` to its `Stored(...)` construction — without this, every message send would silently wipe the cached schedule back to `nil`:
```swift
    private func updateCache(msgCounter: Int? = nil) {
        let real = realMessages()
        guard !real.isEmpty else { return }
        store?.chatCache[character.id] = real
        let stored = LocalConversationStore.shared.load(for: character.id)
        let updated = LocalConversationStore.Stored(
            messages: real,
            xp: stored?.xp ?? 0,
            level: relationshipLevel,
            summary: stored?.summary ?? "",
            summarizedCount: stored?.summarizedCount ?? 0,
            msgCounter: msgCounter ?? stored?.msgCounter ?? 0,
            levelProgress: levelProgress,
            detectedLanguage: ConversationLanguage.resolve(
                latestAssistantText: real.last(where: { $0.role == .assistant })?.content,
                previouslyDetected: stored?.detectedLanguage
            ),
            schedule: stored?.schedule
        )
        LocalConversationStore.shared.save(updated, for: character.id)
    }
```

- [ ] **Step 5: Thread `currentActivity` into `send()`, `sendVoiceRequest()`, `sendImageRequest()`**

In `send()`, locate the `sendWithLocalHistory` call and add the new argument:
```swift
                let result = try await service.sendWithLocalHistory(
                    character: character,
                    localMessages: realMsgs,
                    summary: stored?.summary ?? "",
                    userMessage: text,
                    level: relationshipLevel,
                    lastMessageAt: lastMessageAt,
                    currentActivity: currentActivity?.detail
                )
```

In `sendVoiceRequest()`, its `sendWithLocalHistory` call:
```swift
                let result = try await service.sendWithLocalHistory(
                    character: character,
                    localMessages: realMsgs,
                    summary: stored?.summary ?? "",
                    userMessage: text,
                    level: relationshipLevel,
                    lastMessageAt: lastMessageAt,
                    voiceChat: true,
                    currentActivity: currentActivity?.detail
                )
```

In `sendImageRequest()`, its `sendWithLocalHistory` call:
```swift
                let result = try await service.sendWithLocalHistory(
                    character: character,
                    localMessages: realMsgs,
                    summary: stored?.summary ?? "",
                    userMessage: text,
                    level: relationshipLevel,
                    lastMessageAt: lastMessageAt,
                    imageReactionChat: true,
                    currentActivity: currentActivity?.detail
                )
```

- [ ] **Step 6: Update `triggerSummarizationIfNeeded` for the new return shape**

Replace:
```swift
    private func triggerSummarizationIfNeeded() {
        guard let stored = LocalConversationStore.shared.load(for: character.id) else { return }
        let real = stored.messages.filter { $0.imageURL == nil }
        let windowStart = max(0, real.count - localKeepRecent)
        guard windowStart > stored.summarizedCount else { return }

        let toFold = Array(real[stored.summarizedCount..<windowStart])
        let existingSummary = stored.summary
        let characterId = character.id

        Task.detached(priority: .background) { [service = self.service, character = self.character] in
            guard let newSummary = try? await service.generateLocalSummary(
                character: character,
                messagesToFold: toFold,
                existingSummary: existingSummary
            ) else { return }
            await MainActor.run {
                LocalConversationStore.shared.updateSummary(
                    for: characterId,
                    summary: newSummary,
                    summarizedCount: windowStart
                )
            }
        }
    }
```
with:
```swift
    private func triggerSummarizationIfNeeded() {
        guard let stored = LocalConversationStore.shared.load(for: character.id) else { return }
        let real = stored.messages.filter { $0.imageURL == nil }
        let windowStart = max(0, real.count - localKeepRecent)
        guard windowStart > stored.summarizedCount else { return }

        let toFold = Array(real[stored.summarizedCount..<windowStart])
        let existingSummary = stored.summary
        let previousSchedule = stored.schedule
        let characterId = character.id

        Task.detached(priority: .background) { [service = self.service, character = self.character] in
            guard let result = try? await service.generateLocalSummary(
                character: character,
                messagesToFold: toFold,
                existingSummary: existingSummary,
                previousSchedule: previousSchedule
            ) else { return }
            await MainActor.run {
                LocalConversationStore.shared.updateSummary(
                    for: characterId,
                    summary: result.summary,
                    summarizedCount: windowStart,
                    schedule: result.schedule
                )
                self.refreshCurrentActivity()
            }
        }
    }
```

- [ ] **Step 7: Manual review pass (no Xcode in this sandbox)**

```bash
grep -n "sendWithLocalHistory(\|generateLocalSummary(\|currentActivity" /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend/ViewModels/ChatViewModel.swift
```
Expected: all three `sendWithLocalHistory(` calls now include `currentActivity: currentActivity?.detail`; the single `generateLocalSummary(` call passes `previousSchedule:` and no longer treats the result as a bare `String`.

- [ ] **Step 8: Commit**

```bash
git add aiGirlfriend/ViewModels/ChatViewModel.swift
git commit -m "feat: track and thread currentActivity through ChatViewModel"
```

---

### Task 7: `ChatView.swift` — header status line

**Files:**
- Modify: `aiGirlfriend/Views/ChatView.swift`

**Interfaces:**
- Consumes: `ChatViewModel.currentActivity`, `ChatViewModel.startActivityRefreshLoop()` from Task 6.
- Produces: nothing consumed by later tasks (UI leaf, last task in this plan).

- [ ] **Step 1: Replace the "Online" text with the current activity**

Locate (`ChatView.swift:147-152`):
```swift
                            HStack(spacing: 5) {
                                Circle().fill(Color(hex: 0x4ADE80)).frame(width: 7, height: 7)
                                Text("Online")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
```
Replace with:
```swift
                            HStack(spacing: 5) {
                                Circle().fill(Color(hex: 0x4ADE80)).frame(width: 7, height: 7)
                                Text(viewModel.currentActivity?.label ?? String(localized: "Online"))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
```

- [ ] **Step 2: Start the refresh loop**

Locate the existing `.task { viewModel.store = store; ... }` block (`ChatView.swift:74-82`) and add the refresh loop as a second `.task` modifier directly after it (a separate `.task` so it runs concurrently and is independently cancelled by SwiftUI on disappear):
```swift
        .task {
            await viewModel.startActivityRefreshLoop()
        }
```

- [ ] **Step 3: Manual review pass (no Xcode in this sandbox)**

```bash
grep -n 'Text("Online")\|startActivityRefreshLoop' /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend/Views/ChatView.swift
```
Expected: no remaining bare `Text("Online")` (it's now `Text(viewModel.currentActivity?.label ?? String(localized: "Online"))`), and one `startActivityRefreshLoop` call site.

- [ ] **Step 4: Commit**

```bash
git add aiGirlfriend/Views/ChatView.swift
git commit -m "feat: show live schedule activity in chat header"
```

- [ ] **Step 5: End-to-end manual test (requires a real device/simulator build — flag as owed if unavailable)**

If Xcode is available: open a chat with a fresh character (never opened before), confirm the header briefly shows "Online" then updates to a plausible activity label within a few seconds (initial generation completing). Send 20+ messages establishing a schedule-changing fact (e.g. "I just quit my job") and confirm the header/tone eventually reflects it after the summarization trigger. If Xcode is unavailable in this sandbox, note this step as owed in project memory, matching the existing pattern for every other unverified UI change this session.

---

## Post-plan cleanup

After all 7 tasks are committed, update project memory (`architecture_swift.md`, `architecture_edge_functions.md`, `project_changelog.md`) with the new files/behavior introduced here, following this repo's existing memory-maintenance convention — do this as a normal follow-up conversation turn, not a plan task.
