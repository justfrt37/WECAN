# Engagement, Dramatic Pacing & Auto-Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make chat bots proactively engaged (questions, memory callbacks, topic switches, level-1 sexual interest that scales, day-aware openers/anecdotes) and able to deliver a reply as up to 3 paced bubbles with real delay between them, without adding new API calls or hurting xAI prompt-cache hit rate — and auto-capture durable facts into `memories` without a manual "Anı Ekle" tap.

**Architecture:** All new behavior lives as static prompt-text constants in `supabase/functions/chat/index.ts` (same pattern as the file's existing `TEXTING_STYLE_RULE`/`VARIATION_RULE`/`humorDirective`) plus one new parsing helper (`parseReplySegments`) that splits a `[PAUSE:n]`-tagged reply into timed bubbles. The system-prompt assembly order is changed so variable-per-conversation content (`memories`/`behaviors`/`exHistory`/summary) sits last, maximizing the stable cached prefix. Auto-memory extraction is folded into the summarization Grok call that already exists in the file's "5) Özetleme" block — zero new API calls. Client side, `ChatService.swift` gains an optional `replySegments` field on the wire response, and `ChatViewModel.swift` gets one shared `deliverSegments` helper (replacing 3 duplicated bubble-timing blocks) that plays back either the single legacy bubble or the paced multi-bubble sequence.

**Tech Stack:** Deno edge function (TypeScript, Supabase), Swift/SwiftUI (iOS client), Grok (`grok-4-1-fast-non-reasoning` via xAI API).

## Global Constraints

- No DB schema migrations — `memories` table already accepts `{conversation_id, content}` inserts with no other required columns (verified via `supabase/functions/add-character-note/index.ts:119`).
- No new Grok API calls anywhere in this plan — every new capability piggybacks an existing call.
- Multi-bubble/`[PAUSE:n]` behavior applies ONLY to the main plain-text CEVAP-mode reply path (`!voiceChat && !imageReactionChat` at the point that rule is appended) — `voiceChat`, `imageReactionChat`, and the separate `photoDownloadReaction` branch are explicitly out of scope, left untouched.
- No hardcoded personality-role branching in code for the "shy vs. confident" sexual-interest expression — the model infers this from the character's own persona text already present in `systemPrompt`, matching the existing convention in `sleepRule`/`wrapDirective`.
- Neither the Deno functions directory nor the Swift app has an automated test suite (confirmed: no test files exist for `chat/index.ts` or any `ViewModel`/`Service` file). Verification in this plan is manual: local `supabase functions serve` + `curl` for server changes, Xcode build + manual multi-turn chat session for client changes — matching the verification approach used in this repo's other spec docs (e.g. `docs/superpowers/specs/2026-07-05-*`). Do not introduce a new test framework as part of this plan.
- Design spec: `docs/superpowers/specs/2026-07-27-engagement-pacing-memory-design.md`.

---

### Task 1: Server — engagement, dramatic pacing, and day-awareness prompt directives

**Files:**
- Modify: `supabase/functions/chat/index.ts:424-454` (insert new functions after `humorDirective`, before `timeContext`)
- Modify: `supabase/functions/chat/index.ts:437-454` (`timeContext` function body — extend for day-awareness)
- Modify: `supabase/functions/chat/index.ts:893-906` (`turnContext` assembly — loosen `currentActivity` block for day-talk exception)
- Modify: `supabase/functions/chat/index.ts:860-873` (system-prompt rule assembly — wire in new directives)

**Interfaces:**
- Produces: `engagementDirective(level: number): string`, `DRAMATIC_PACING_RULE: string` (both consumed by Task 1's own assembly step and read by no other task).
- Produces: extended `timeContext(lastMs, nowMs, tzMin): string` — same signature, richer output, still consumed at `chat/index.ts:893` (`timeContext(lastMessageAt, clientNow, tzOffsetMinutes)`).

- [ ] **Step 1: Add `engagementDirective` and `DRAMATIC_PACING_RULE`**

Insert immediately after the closing brace of `humorDirective` (currently ending at line 435, right before the `// Son mesajdan bu yana geçen süre...` comment that precedes `timeContext`):

```ts
// KULLANICIYA İLGİ/MERAK KURALI: bot sadece cevap verip beklemesin, aktif
// olarak meşgul olsun — soru sorsun, [MEMORIES]/[SHARED HISTORY]/özet
// bloklarındaki bilgileri kullanıp geçmiş konuşmalara gönderme yapsın, ara
// sıra (HER turda değil) konuyu kendi başına değiştirsin. Cinsel/romantik
// ilgi seviye 1'den itibaren VAR — fetchDirective'den gelen aşama
// direktifinden BAĞIMSIZ bir taban katman, seviyeyle yoğunluğu artar ama
// asla "kapalı" değildir. Yoğunluk/ifade biçimi KARAKTERİN KENDİ sesinden
// süzülür: çekingen/mesafeli bir karakter bunu dolaylı yollardan (şaka,
// kelime oyunu, ima) gösterir, kendinden emin bir karakter doğrudan
// gösterir — hangisi olduğuna yukarıdaki karakter tanımından model karar
// verir, koddan gelen sabit bir kural değil.
function engagementDirective(level: number): string {
  const intensity =
    level <= 2 ? "hafif, keşif aşamasında bir ilgi" :
    level <= 5 ? "belirgin, açıkça hissettirilen bir ilgi" :
    level <= 8 ? "yoğun, doğrudan flörtöz bir ilgi" :
    "tamamen açık, tutkulu bir ilgi";
  return (
    "\n\nİLGİ VE MERAK KURALI: Sadece cevap verip durma — kullanıcıya karşı " +
    "gerçekten meraklı biri gibi davran. Soru sor, onun hakkında daha fazla " +
    "şey öğrenmek iste. [MEMORIES], [SHARED HISTORY] ve özet bloklarındaki " +
    "bilgileri PASİF şekilde sadece sorulunca değil, AKTİF olarak kullan — " +
    "geçmişte konuştuğunuz bir şeye gönderme yap, 'o iş nasıl gitti' tarzı " +
    "takip sorusu sor. Ara sıra (HER mesajda değil, doğal aralıklarla) " +
    "konuşmayı kendi başına yeni bir konuya çevir — bir soru, bir gözlem, " +
    "aklına gelen bir şey; ilgi alanlarını (varsa) ya da genel merakını " +
    "kullan.\n\nCİNSEL/ROMANTİK İLGİ: Bu ilişkinin şu anki yakınlık " +
    `seviyesinde ${intensity} göster — bu HER seviyede vardır, hiçbir zaman ` +
    "tamamen kapalı değildir, sadece yoğunluğu/açıklığı değişir. Bunu NASIL " +
    "gösterdiğin tamamen kendi karakterine bağlı: yukarıdaki karakter " +
    "tanımın çekingen/mesafeli/utangaç bir kişiliği anlatıyorsa bu ilgiyi " +
    "DOLAYLI yollardan göster (şaka, kelime oyunu, ima, kızarma/tedirginlik " +
    "gibi tepkiler) — asla doğrudan bir itiraf gibi değil. Kendinden emin/" +
    "flörtöz bir kişiliği anlatıyorsa doğrudan gösterebilirsin. Bu senin " +
    "kendi karakter tanımından çıkarman gereken bir şey, sabit bir kural " +
    "değil."
  );
}

// DRAMATİK TEMPO KURALI: model bazen cevabını [PAUSE:n] etiketiyle (n=1-5,
// saniye) ayrılmış en fazla 3 kısa parçaya bölebilir — istemci her parçayı
// ayrı bir mesaj balonu olarak, aralarında "yazıyor..." animasyonuyla
// gösterir (bkz. parseReplySegments, Task 2). SADECE düz metin turlarında
// eklenir (bkz. çağrı yeri) — voiceChat/imageReactionChat turlarında bu
// kural hiç enjekte edilmez.
const DRAMATIC_PACING_RULE =
  "\n\nDRAMATİK TEMPO KURALI: Gerçek bir an duraksama/işleme/gerilim " +
  "gerektiriyorsa (ör. kullanıcı beklenmedik bir şey söyledi, tepkini " +
  "hemen değil biraz duraksadıktan sonra vermek istiyorsun, ya da sadece " +
  "art arda iki kısa mesaj atan gerçek biri gibi davranmak istiyorsun) " +
  "cevabını [PAUSE:n] etiketiyle (n 1 ile 5 arasında bir sayı, saniye " +
  "cinsinden) ayrılmış EN FAZLA 3 kısa parçaya bölebilirsin — ör. " +
  "'ilk parça[PAUSE:2]ikinci parça'. Bu SADECE gerçekten anlamlı bir an " +
  "için, çoğu mesajda kullanma — her cevabı bölme, sadece gerçekten hak " +
  "eden anlarda. Etiketi doğaçlama kullan, sabit bir kalıp/örnek tekrarlama; " +
  "her seferinde kendi anına uygun farklı bir bölünme/süre seç.";
```

- [ ] **Step 2: Extend `timeContext` for day-awareness**

Replace the existing `timeContext` function body (`chat/index.ts:438-454`):

```ts
function timeContext(lastMs?: number, nowMs?: number, tzMin?: number): string {
  if (typeof lastMs !== "number" || typeof nowMs !== "number") return "";
  const gapS = Math.max(0, (nowMs - lastMs) / 1000);
  let gap: string;
  if (gapS < 120) gap = "az önce (birkaç saniye/dakika)";
  else if (gapS < 3600) gap = `${Math.round(gapS / 60)} dakika`;
  else if (gapS < 86400) gap = `${Math.round(gapS / 3600)} saat`;
  else gap = `${Math.round(gapS / 86400)} gün`;
  const localHour = Math.floor((((nowMs / 1000) + (tzMin ?? 0) * 60) % 86400) / 3600);
  const partOfDay =
    localHour < 6 ? "gece geç saat" : localHour < 12 ? "sabah" :
    localHour < 18 ? "öğleden sonra" : "akşam";
  return `\n\n[ZAMAN] Kullanıcının son mesajından bu yana ~${gap} geçti. ` +
    `Şu an ${partOfDay} (yaklaşık saat ${localHour}). Buna uygun, doğal davran: ` +
    `uzun aradan sonra bunu doğal şekilde belli et (özledim / neredeydin gibi), ` +
    `günün saatine göre ton/selam seç. Bunu her mesajda tekrar etme, sadece uygunsa. ` +
    `Bu zaman farkındalığını sadece pasif bir ton ipucu olarak değil, ARA SIRA ` +
    `bir konuşma açılışı olarak da kullanabilirsin — ör. günün nasıl geçtiğini ` +
    `sor, uzun bir aradan sonra ne yaptığını merak et. Her turda sorma, sadece ` +
    `doğal geldiğinde.`;
}
```

(Only the final sentence-and-a-half — starting at "Bu zaman farkındalığını" — is new; everything before it is unchanged.)

- [ ] **Step 3: Loosen the `currentActivity` block for day-talk**

In the `turnContext` assembly, find (`chat/index.ts:894-906`):

```ts
    if (currentActivity) {
      // Sert yasak (önceki hali "her mesajda tekrarlama" gibi yumuşak bir
      // rica idi — model yine de neredeyse her turda aktiviteden bahsediyordu,
      // çünkü context her turda yeniden enjekte ediliyor). Artık SADECE tona
      // yansır, kullanıcı doğrudan sormadıkça metinde HİÇ geçmez.
      turnContext += `\n\n[CURRENT ACTIVITY — INTERNAL, DO NOT MENTION] You ` +
        `are currently: ${currentActivity}. Let this shape your TONE ONLY ` +
        `(e.g. short/distracted if at work, relaxed/chattier if at home). ` +
        `Do NOT say, describe, or hint at what you're doing — only bring it ` +
        `up if the user explicitly asks what you're doing right now. Never ` +
        `mention it turn after turn just because it's in this context; ` +
        `that reads robotic and repetitive.`;
    }
```

Replace with:

```ts
    if (currentActivity) {
      // Sert yasak (önceki hali "her mesajda tekrarlama" gibi yumuşak bir
      // rica idi — model yine de neredeyse her turda aktiviteden bahsediyordu,
      // çünkü context her turda yeniden enjekte ediliyor). Artık SADECE tona
      // yansır, kullanıcı doğrudan sormadıkça metinde HİÇ geçmez — TEK istisna
      // "günün nasıl geçti" tarzı bir day-talk anı (bkz. DAY TALK EXCEPTION).
      turnContext += `\n\n[CURRENT ACTIVITY — INTERNAL, DO NOT MENTION] You ` +
        `are currently: ${currentActivity}. Let this shape your TONE ONLY ` +
        `(e.g. short/distracted if at work, relaxed/chattier if at home). ` +
        `Do NOT say, describe, or hint at what you're doing — only bring it ` +
        `up if the user explicitly asks what you're doing right now. Never ` +
        `mention it turn after turn just because it's in this context; ` +
        `that reads robotic and repetitive.\n\n[DAY TALK EXCEPTION] If the ` +
        `user asks how your day is/was, or right after YOU ask them about ` +
        `their day, you may improvise a short, natural account of your own ` +
        `day — consistent with the activity above and your character's ` +
        `general schedule, but elaborated into a small, believable anecdote ` +
        `(not just repeating the label). Never reuse the same fake day twice ` +
        `— improvise it fresh each time, staying broadly consistent with ` +
        `what you've said before if it comes up again.`;
    }
```

- [ ] **Step 4: Wire `engagementDirective`/`DRAMATIC_PACING_RULE` into the system-prompt assembly**

Find (`chat/index.ts:860-873`):

```ts
    system += languageDirective(detectedLanguage);
    system += TEXTING_STYLE_RULE;
    system += VARIATION_RULE;
    system += CONTINUITY_RULE;
    system += humorDirective(currentLevel);
    if (voiceChat) {
      system += VOICE_TAGS_RULE;
    }
    if (imageReactionChat) {
      system += imageRedirected ? IMAGE_REDIRECT_RULE : IMAGE_CAPTION_RULE;
    }
    if (hasUserPhoto) {
      system += USER_PHOTO_REACTION_RULE;
    }
    if (useClientHistory && localSummary && localSummary.trim() !== "") {
      system += `\n\n[Önceki konuşmalarınızın özeti]\n${stripVoiceTags(localSummary)}`;
    }

    // Sadece DÜZ metin turlarında — voiceChat/imageReactionChat zaten düğme
    // akışının kendisi, o turlarda bu uyarı anlamsız/çelişkili olurdu.
    if (!voiceChat && !imageReactionChat) {
      system += MEDIA_REQUEST_RULE;
      system += sleepRule(personalityRole, currentLevel);
    }
    if (!useClientHistory && convo.summary && convo.summary.trim() !== "") {
      system += `\n\n[Summary of your previous conversations — reference naturally, reply in the user's language regardless]\n${stripVoiceTags(convo.summary)}`;
    }
```

Replace with:

```ts
    system += languageDirective(detectedLanguage);
    system += TEXTING_STYLE_RULE;
    system += VARIATION_RULE;
    system += CONTINUITY_RULE;
    system += humorDirective(currentLevel);
    system += engagementDirective(currentLevel);
    if (voiceChat) {
      system += VOICE_TAGS_RULE;
    }
    if (imageReactionChat) {
      system += imageRedirected ? IMAGE_REDIRECT_RULE : IMAGE_CAPTION_RULE;
    }
    if (hasUserPhoto) {
      system += USER_PHOTO_REACTION_RULE;
    }

    // Sadece DÜZ metin turlarında — voiceChat/imageReactionChat zaten düğme
    // akışının kendisi, o turlarda bu uyarı anlamsız/çelişkili olurdu.
    if (!voiceChat && !imageReactionChat) {
      system += MEDIA_REQUEST_RULE;
      system += sleepRule(personalityRole, currentLevel);
      system += DRAMATIC_PACING_RULE;
    }

    // ── Buradan sonrası konuşma bazında DEĞİŞEBİLEN içerik (exHistory hariç
    // hepsi mesaj geçtikçe büyür/güncellenir) — kasıtlı olarak system'in EN
    // SONUNA taşındı: xAI prompt-cache prefix eşleşmesi bu noktadan öncesini
    // (yukarıdaki tüm statik kural bloklarını) korur, bu blok değiştiğinde
    // SADECE kendisinden sonrası (turnContext zaten user mesajında, bunun
    // dışında) geçersiz olur — bkz. design doc §3, docs.x.ai prompt-caching.
    if (exHistory) {
      system += `\n\n[SHARED HISTORY — reference these memories naturally in conversation]\n${exHistory}`;
    }
    if (memoryRows && memoryRows.length > 0) {
      system += `\n\n[MEMORIES — facts to remember about the user/relationship]\n` +
        memoryRows.map((m) => `- ${m.content}`).join("\n");
    }
    if (behaviorRows && behaviorRows.length > 0) {
      system += `\n\n[BEHAVIOR PREFERENCES — how the user wants you to act]\n` +
        behaviorRows.map((b) => `- ${b.content}`).join("\n");
    }
    if (useClientHistory && localSummary && localSummary.trim() !== "") {
      system += `\n\n[Önceki konuşmalarınızın özeti]\n${stripVoiceTags(localSummary)}`;
    }
    if (!useClientHistory && convo.summary && convo.summary.trim() !== "") {
      system += `\n\n[Summary of your previous conversations — reference naturally, reply in the user's language regardless]\n${stripVoiceTags(convo.summary)}`;
    }
```

Now find the ORIGINAL `exHistory`/`memoryRows`/`behaviorRows` append block earlier in the function (`chat/index.ts:834-858`):

```ts
    if (exHistory) {
      system += `\n\n[SHARED HISTORY — reference these memories naturally in conversation]\n${exHistory}`;
    }

    // Kullanıcının "Anı Ekle" / "Davranış Ekle" ile eklediği kalıcı notlar
    // (her rol için geçerli — ex'e özel değil).
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
    if (memoryRows && memoryRows.length > 0) {
      system += `\n\n[MEMORIES — facts to remember about the user/relationship]\n` +
        memoryRows.map((m) => `- ${m.content}`).join("\n");
    }
    if (behaviorRows && behaviorRows.length > 0) {
      system += `\n\n[BEHAVIOR PREFERENCES — how the user wants you to act]\n` +
        behaviorRows.map((b) => `- ${b.content}`).join("\n");
    }
```

Replace it with just the DB fetch (drop the `system +=` calls here — they now happen at the end of the block edited above; `memoryRows`/`behaviorRows` stay in scope as `const` for the rest of the function, e.g. Task 3 needs `memoryRows`):

```ts
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

- [ ] **Step 5: Manual verification — directive text renders correctly**

No local Grok credentials assumed available to every implementer; verification here is a static check, not a live model call:

Run: `deno check supabase/functions/chat/index.ts` (or `npx -y typescript@latest --noEmit` if `deno` isn't installed — the file is plain TS/Deno syntax) to confirm no syntax errors were introduced by the reordering.

Expected: no type/syntax errors.

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/chat/index.ts
git commit -m "$(cat <<'EOF'
feat(chat): add engagement, dramatic-pacing, and day-awareness directives

Adds engagementDirective (level-1 sexual interest baseline, proactive
questions/memory callbacks, occasional topic switches) and
DRAMATIC_PACING_RULE ([PAUSE:n] multi-bubble tag), extends timeContext
and the currentActivity block for day-aware conversation openers/
anecdotes, and reorders the system prompt so variable per-conversation
content (memories/behaviors/exHistory/summary) sits last for better
xAI prompt-cache hit rate.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Server — multi-bubble `[PAUSE:n]` parsing and response wiring

**Files:**
- Modify: `supabase/functions/chat/index.ts` (add `parseReplySegments` near `extractJson`, wire into CEVAP mode)

**Interfaces:**
- Consumes: nothing new (pure string transform).
- Produces: `parseReplySegments(raw: string): { plainText: string; segments: { text: string; delaySeconds: number }[] }`, used by this task's own response-wiring step. Response JSON gains `replySegments: { text: string; delaySeconds: number }[]`, consumed by Task 4 (`ChatResponse.replySegments` on the client).

- [ ] **Step 1: Add `parseReplySegments`**

Insert right after `extractJson` (`chat/index.ts:65-69`, before the `stripVoiceTags` comment block):

```ts
// [PAUSE:n] etiketiyle bölünmüş bir cevabı zamanlı parçalara ayırır (bkz.
// DRAMATIC_PACING_RULE). Modelin ne yazarsa yazsın: gecikme 1-5 saniyeye
// sıkıştırılır, toplam parça sayısı 3 ile sınırlanır (3'ten fazlası son
// parçaya birleştirilir) — savunma amaçlı, kural zaten modele bu sınırları
// söylüyor ama sunucu asla modele güvenmez.
function parseReplySegments(raw: string): {
  plainText: string;
  segments: { text: string; delaySeconds: number }[];
} {
  const parts = raw.split(/\[PAUSE:(\d+)\]/);
  // split with a capturing group interleaves text/delay/text/delay/...text
  const rawSegments: { text: string; delaySeconds: number }[] = [];
  for (let i = 0; i < parts.length; i += 2) {
    const text = parts[i].trim();
    if (!text) continue;
    const delaySeconds = i > 0 ? Math.min(5, Math.max(1, parseInt(parts[i - 1], 10) || 1)) : 0;
    rawSegments.push({ text, delaySeconds });
  }
  if (rawSegments.length === 0) return { plainText: raw.trim(), segments: [] };
  const capped = rawSegments.length > 3
    ? [
        ...rawSegments.slice(0, 2),
        {
          text: rawSegments.slice(2).map((s) => s.text).join(" "),
          delaySeconds: rawSegments[2].delaySeconds,
        },
      ]
    : rawSegments;
  return {
    plainText: capped.map((s) => s.text).join(" "),
    segments: capped,
  };
}
```

- [ ] **Step 2: Wire into CEVAP mode — use `plainText` for storage/classification, return `segments`**

Find (`chat/index.ts:964-983`, the CEVAP-mode reply handling):

```ts
    const reply = await callGrok(grokMessages, 600, conversationId);

    // Gerçek atomik düşüm — cevap başarıyla üretildi, şimdi tahsil et.
    let tokenBalanceAfterCharge: number | undefined;
    if (!voiceChat && !imageReactionChat) {
      const charge = await chargeOrReject(uid, 1, "message");
      if (charge.ok) tokenBalanceAfterCharge = charge.balance;
    }

    const wentToSleep = (!voiceChat && !imageReactionChat && nearSleepTime)
      ? await classifySleepAgreement(userMessage!, reply)
      : false;

    // 4) Mesajları kaydet — clientHistory modunda istemci kendi saklıyor, DB'ye yazma
    if (!useClientHistory) {
      await db.from("messages").insert([
        { conversation_id: conversationId, role: "user", content: userMessage!, kind: "text" },
        { conversation_id: conversationId, role: "assistant", content: reply, kind: "text" },
      ]);
    }
```

Replace with:

```ts
    const rawReply = await callGrok(grokMessages, 600, conversationId);
    // [PAUSE:n] parsing only makes sense for plain-text turns — voice/image-
    // reaction turns never get DRAMATIC_PACING_RULE injected, so `segments`
    // is always empty for them and `replySegments` stays unset in the response.
    const { plainText: reply, segments: replySegments } =
      (!voiceChat && !imageReactionChat) ? parseReplySegments(rawReply) : { plainText: rawReply, segments: [] };

    // Gerçek atomik düşüm — cevap başarıyla üretildi, şimdi tahsil et.
    let tokenBalanceAfterCharge: number | undefined;
    if (!voiceChat && !imageReactionChat) {
      const charge = await chargeOrReject(uid, 1, "message");
      if (charge.ok) tokenBalanceAfterCharge = charge.balance;
    }

    const wentToSleep = (!voiceChat && !imageReactionChat && nearSleepTime)
      ? await classifySleepAgreement(userMessage!, reply)
      : false;

    // 4) Mesajları kaydet — clientHistory modunda istemci kendi saklıyor, DB'ye yazma
    if (!useClientHistory) {
      await db.from("messages").insert([
        { conversation_id: conversationId, role: "user", content: userMessage!, kind: "text" },
        { conversation_id: conversationId, role: "assistant", content: reply, kind: "text" },
      ]);
    }
```

Then find the two `return json({ conversationId, reply, level: newLevel, levelProgress: newProgress, wentToSleep, tokenBalance: tokenBalanceAfterCharge });` lines (`chat/index.ts:1015` and `1073`) and replace BOTH with:

```ts
      return json({ conversationId, reply, replySegments, level: newLevel, levelProgress: newProgress, wentToSleep, tokenBalance: tokenBalanceAfterCharge });
```

(the first occurrence, inside the `if (useClientHistory) { ... }` early-return, keeps its surrounding `if` block and indentation — only the `json({...})` argument list changes; the second occurrence is the function's final `return`).

- [ ] **Step 3: Manual verification**

Run: `deno check supabase/functions/chat/index.ts`
Expected: no type/syntax errors.

Run locally if `supabase` CLI + `.env` with `XAI_API_KEY` are available: `supabase functions serve chat` in one terminal, then in another:

```bash
curl -s -X POST http://localhost:54321/functions/v1/chat \
  -H "Authorization: Bearer <a valid user JWT>" \
  -H "Content-Type: application/json" \
  -d '{"characterId":"<existing character id>","systemPrompt":"Test character.","userMessage":"tell me something dramatic"}' | python3 -m json.tool
```

Expected: response includes a `replySegments` key (array, possibly empty) and `reply` is the tag-free concatenation of any `[PAUSE:n]`-split parts the model produced. If no local Grok credentials are available, skip this curl check and rely on Step 3's static `deno check` plus the Task 5 end-to-end client test, which exercises this same code path.

- [ ] **Step 4: Commit**

```bash
git add supabase/functions/chat/index.ts
git commit -m "$(cat <<'EOF'
feat(chat): parse [PAUSE:n] tags into timed reply segments

parseReplySegments splits a plain-text CEVAP-mode reply on [PAUSE:n]
tags (clamped 1-5s, capped at 3 segments), storing the tag-free
plainText as before and returning the segment list as a new
replySegments field for the client to animate as paced bubbles.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Server — auto-memory extraction folded into existing summarization

**Files:**
- Modify: `supabase/functions/chat/index.ts:1018-1071` (the "5) Özetleme" block, inside the main CEVAP-mode handler — NOT the separate `summarizeMessages` client-triggered branch, see note below)

**Interfaces:**
- Consumes: `memoryRows` (from Task 1 Step 4's fetch, already in scope as a `const` at this point in the function), `conversationId` (already in scope).
- Produces: nothing consumed by other tasks — this task is self-contained.

> **Note on deviation from the design doc:** the design doc (§5) describes hooking into the client-triggered `summarizeMessages` branch by adding `conversationId` to that request. Investigation during planning found that branch is effectively vestigial for the main chat flow — `useClientHistory` is hardcoded to `false` (`chat/index.ts:593`), so the client-side summary it produces is never read by the CEVAP-mode system prompt (`chat/index.ts:884` only reads `convo.summary`, the DB-side value). The DB-side summary — the one that actually matters — is produced by the "5) Özetleme" block inside the main handler (`chat/index.ts:1018-1071`), which already has `conversationId` in scope and already calls Grok once per ~20 aged-out messages. Hooking auto-memory extraction there achieves the same goal (piggyback an existing call, no new API call, no new client wiring) more directly and doesn't require touching `ChatService.swift`/`ChatViewModel.swift` for this task at all.

- [ ] **Step 1: Extend the summarization prompt to also extract new memory facts**

Find (`chat/index.ts:1038-1060`, inside the `if (agedOut > summarizedCount) { ... }` block):

```ts
        const summaryPrompt: WireMessage[] = [
          {
            role: "system",
            content:
              "You maintain a running conversation summary for an AI companion character, in English " +
              "regardless of what language the conversation itself was in. It has two parts, and you must " +
              "keep BOTH updated — not just the user side:\n\n" +
              "USER — facts and intents: name, preferences, relationship status/key moments, promises made, " +
              "ongoing topics, what the user seems to want from the character.\n\n" +
              "BOT — established behavior: the tone/persona choices the character has actually settled into " +
              "in this conversation (e.g. teasing vs. gentle, pet names used, boundaries respected, running " +
              "jokes or bits, commitments the character made) — so future turns stay consistent with how the " +
              "character has already been behaving, not just generic persona instructions.\n\n" +
              "Short bullet points under each heading. Keep prior summary content, fold in what's new, drop " +
              "anything superseded or no longer relevant.",
          },
          {
            role: "user",
            content:
              `Previous summary:\n${convo.summary || "(none)"}\n\n` +
              `New conversation turns:\n${convoText}\n\nUpdated summary (USER / BOT):`,
          },
        ];
        try {
          const newSummary = await callGrok(summaryPrompt, 400);
          await db.from("conversations")
            .update({ summary: newSummary, summarized_count: agedOut })
            .eq("id", conversationId);
        } catch (e) {
          // Özetleme başarısız olsa bile sohbet bozulmaz; sadece logla.
          console.error("ozetleme hatasi:", String(e));
        }
```

Replace with:

```ts
        const existingMemoryLines = (memoryRows ?? []).map((m) => `- ${m.content}`).join("\n") || "(none yet)";
        const summaryPrompt: WireMessage[] = [
          {
            role: "system",
            content:
              "You maintain a running conversation summary for an AI companion character, in English " +
              "regardless of what language the conversation itself was in. It has two parts, and you must " +
              "keep BOTH updated — not just the user side:\n\n" +
              "USER — facts and intents: name, preferences, relationship status/key moments, promises made, " +
              "ongoing topics, what the user seems to want from the character.\n\n" +
              "BOT — established behavior: the tone/persona choices the character has actually settled into " +
              "in this conversation (e.g. teasing vs. gentle, pet names used, boundaries respected, running " +
              "jokes or bits, commitments the character made) — so future turns stay consistent with how the " +
              "character has already been behaving, not just generic persona instructions.\n\n" +
              "Short bullet points under each heading. Keep prior summary content, fold in what's new, drop " +
              "anything superseded or no longer relevant.\n\n" +
              "SEPARATELY, also extract any NEW durable atomic facts worth permanently remembering (name, " +
              "preferences, promises, key relationship moments) that are NOT already covered by the existing " +
              "memories list you'll be given — do not repeat anything already in that list, even reworded. " +
              "If there's nothing new, return an empty array.\n\n" +
              'Respond with ONLY this JSON shape, nothing else: {"summary":"...","newMemories":["fact one",' +
              '"fact two"]} — `summary` is the full updated USER/BOT summary text (same format as before), ' +
              "`newMemories` is the new-facts array described above (can be empty).",
          },
          {
            role: "user",
            content:
              `Previous summary:\n${convo.summary || "(none)"}\n\n` +
              `Existing memories (do not repeat these):\n${existingMemoryLines}\n\n` +
              `New conversation turns:\n${convoText}\n\nUpdated JSON:`,
          },
        ];
        try {
          const raw = await callGrok(summaryPrompt, 500);
          const parsed = extractJson(raw);
          const newSummary: string = typeof parsed?.summary === "string" ? parsed.summary : raw.trim();
          await db.from("conversations")
            .update({ summary: newSummary, summarized_count: agedOut })
            .eq("id", conversationId);
          const newMemories: string[] = Array.isArray(parsed?.newMemories)
            ? parsed.newMemories.filter((m: unknown): m is string => typeof m === "string" && m.trim().length > 0)
            : [];
          if (newMemories.length > 0) {
            await db.from("memories").insert(
              newMemories.map((content) => ({ conversation_id: conversationId, content: content.trim() }))
            );
          }
        } catch (e) {
          // Özetleme başarısız olsa bile sohbet bozulmaz; sadece logla.
          console.error("ozetleme hatasi:", String(e));
        }
```

- [ ] **Step 2: Manual verification**

Run: `deno check supabase/functions/chat/index.ts`
Expected: no type/syntax errors. `extractJson` is already defined earlier in the file (`chat/index.ts:65-69`) and reused here — confirm no duplicate-declaration error.

If local Grok credentials are available, the fastest live check is sending 21+ plain-text messages to the same `(user, character)` pair via the running `chat` function (each real reply triggers the aged-out check once `total - KEEP_RECENT > summarizedCount`), then querying:

```bash
# via supabase CLI or psql against the local/dev DB
select content, created_at from memories where conversation_id = '<conversation id>' order by created_at;
```

Expected: any new atomic facts mentioned in that batch of messages appear as rows; re-running another 20-message batch with no new facts should insert nothing (dedup via the "existing memories" prompt block).

- [ ] **Step 3: Commit**

```bash
git add supabase/functions/chat/index.ts
git commit -m "$(cat <<'EOF'
feat(chat): auto-extract durable memories during existing summarization

Extends the existing per-20-message summarization Grok call to also
output newMemories (deduped against the conversation's current
memories rows) and inserts them into the memories table — no new API
call, memories are no longer only captured via manual "Anı Ekle".

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Client — `ReplySegment` wire type and `ChatReply`/`ChatResponse` plumbing

**Files:**
- Modify: `aiGirlfriend/Services/ChatService.swift`

**Interfaces:**
- Produces: `struct ReplySegment: Codable, Hashable { let text: String; let delaySeconds: Double }` (public, non-`private`) — consumed by Task 5 (`ChatViewModel.deliverSegments`).
- Produces: `ChatReply.replySegments: [ReplySegment]?` — consumed by Task 5.

- [ ] **Step 1: Add wire + public `ReplySegment` types, extend `ChatResponse`/`ChatReply`**

In `ChatService.swift`, find (line 61-64):

```swift
private struct WireMessage: Codable {
    let role: String
    let content: String
}
```

Add right after it:

```swift
private struct WireReplySegment: Codable {
    let text: String
    let delaySeconds: Double
}

/// One paced bubble of a bot reply — see chat/index.ts parseReplySegments.
/// `delaySeconds` for the FIRST segment is always 0 (existing typing-bubble
/// timing already covers it); later segments show the typing indicator for
/// `delaySeconds` before appearing.
struct ReplySegment: Codable, Hashable {
    let text: String
    let delaySeconds: Double
}
```

Find `ChatResponse` (line 66-84) and add one field, right after `let reply: String?` (line 68):

```swift
    let reply: String?
    /// Paced multi-bubble breakdown of `reply` (see DRAMATIC_PACING_RULE /
    /// parseReplySegments server-side). Absent or empty for voice/image-
    /// reaction turns and any older response shape — callers must fall back
    /// to a single bubble built from `reply` in that case.
    let replySegments: [WireReplySegment]?
```

Find `ChatReply` (line 92-102) and add one field, right after `let reply: String` (line 93):

```swift
    let reply: String
    /// See `ChatResponse.replySegments`.
    let replySegments: [ReplySegment]?
```

- [ ] **Step 2: Populate `replySegments` at every `ChatReply(...)` construction site**

There are 3 construction sites in this file. For each, add `replySegments: resp.replySegments?.map { ReplySegment(text: $0.text, delaySeconds: $0.delaySeconds) },` right after the `reply:` line.

`send` (line 209-216):

```swift
        return ChatReply(
            reply: resp.reply ?? "",
            replySegments: resp.replySegments?.map { ReplySegment(text: $0.text, delaySeconds: $0.delaySeconds) },
            level: resp.level ?? level,
            levelProgress: resp.levelProgress,
            photoURL: resp.photoUrl.flatMap(URL.init(string:)),
            wentToSleep: resp.wentToSleep ?? false,
            tokenBalance: resp.tokenBalance
        )
```

`sendWithLocalHistory` (line 254-261) — same pattern, same insertion point.

`sendUserPhotoMessage` (line 295-302) — same pattern, same insertion point. That's all 3.

- [ ] **Step 3: Build check**

Run: `xcodebuild -project aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -50`
(adjust `-project`/`-scheme` to match the actual project file if named differently — check with `ls *.xcodeproj *.xcworkspace` first)

Expected: build succeeds, no "missing argument for parameter 'replySegments'" errors.

- [ ] **Step 4: Commit**

```bash
git add aiGirlfriend/Services/ChatService.swift
git commit -m "$(cat <<'EOF'
feat(chat): decode replySegments from the chat edge function

Adds ReplySegment (text + delaySeconds) and wires it through
ChatResponse/ChatReply so ChatViewModel can animate paced multi-bubble
replies instead of always rendering one bubble.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Client — paced multi-bubble delivery in `ChatViewModel`

**Files:**
- Modify: `aiGirlfriend/ViewModels/ChatViewModel.swift`

**Interfaces:**
- Consumes: `ChatReply.replySegments: [ReplySegment]?` (Task 4), `ReplySegment { text: String; delaySeconds: Double }` (Task 4), `TypingTiming.duration(forReplyLength:)` (existing, `aiGirlfriend/Models/TypingTiming.swift:23`).
- Produces: `private func deliverSegments(_ result: ChatReply, bubbleStartedAt: Date) async` — used only within this file, by `send()`, `sendUserVoice()`, `sendUserPhoto()`.

- [ ] **Step 1: Add the shared `deliverSegments` helper**

Insert into `ChatViewModel.swift` right before the `applyPostReplyEffects` method (line 860, right after the closing brace of `sendUserPhoto` at line 495 works too — place it in the `// MARK: - Mesaj gönder` section, after `send()` ends at line 324):

```swift
    /// `send()`/`sendUserVoice()`/`sendUserPhoto()` ortak balon teslim mantığı —
    /// üçünde de aynı 20 satırlık "kalan süre kadar bekle, balonu kapat, mesajı
    /// ekle" bloğu tekrarlanıyordu, artık tek yerde. `result.replySegments`
    /// doluysa (bkz. DRAMATIC_PACING_RULE) her parçayı ayrı bir balon olarak,
    /// aralarında `delaySeconds` kadar "yazıyor..." göstererek art arda ekler;
    /// boşsa/nil ise eski tek-balon davranışına düşer (voice/image-reaction
    /// turları ve her türlü eski sunucu cevabı için sıfır riskli geri dönüş).
    private func deliverSegments(_ result: ChatReply, bubbleStartedAt: Date) async {
        let segments: [ReplySegment] = (result.replySegments?.isEmpty == false)
            ? result.replySegments!
            : [ReplySegment(text: result.reply, delaySeconds: 0)]

        for (index, segment) in segments.enumerated() {
            if index == 0 {
                // İlk parça: mevcut davranış — balon zaten çağrı ÖNCESİNDE
                // açılmıştı, sadece "bunu yazmak ne kadar sürerdi" kadar tamamla.
                let elapsed = Date().timeIntervalSince(bubbleStartedAt)
                let wanted = TypingTiming.duration(forReplyLength: segment.text.count)
                let remaining = wanted - elapsed
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
            } else {
                // Sonraki parçalar: balonu YENİDEN aç, dramatik duraklamayı
                // "yazıyor..." animasyonuyla göster.
                showsTypingBubble = true
                store?.setTyping(character.id, true)
                try? await Task.sleep(nanoseconds: UInt64(segment.delaySeconds * 1_000_000_000))
            }
            showsTypingBubble = false
            store?.setTyping(character.id, false)
            messages.append(Message(role: .assistant, content: segment.text))
        }
    }
```

- [ ] **Step 2: Use it in `send()`**

Find (`ChatViewModel.swift:285-300`):

```swift
                // Cevap hazır olsa bile, balon en az "bunu yazmak ne kadar sürerdi"
                // kadar açık kalsın (2x insan hızı, ama üst sınırla sıkıştırılmış).
                let elapsed = Date().timeIntervalSince(bubbleStartedAt)
                let wanted = TypingTiming.duration(forReplyLength: result.reply.count)
                let remaining = wanted - elapsed
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                showsTypingBubble = false
                store?.setTyping(character.id, false)

                // Eski otomatik-foto sistemi (metinde "foto" geçince statik
                // havuzdan rastgele fotoğraf ekleme) KALDIRILDI — artık foto/ses
                // sadece ilgili düğmeyle gönderilir (bkz. MEDIA_REQUEST_RULE,
                // chat/index.ts). Grok bu turda düğmeyi kullanmasını önerir.
                messages.append(Message(role: .assistant, content: result.reply))
                handleTokenBalance(result.tokenBalance)
```

Replace with:

```swift
                // Eski otomatik-foto sistemi (metinde "foto" geçince statik
                // havuzdan rastgele fotoğraf ekleme) KALDIRILDI — artık foto/ses
                // sadece ilgili düğmeyle gönderilir (bkz. MEDIA_REQUEST_RULE,
                // chat/index.ts). Grok bu turda düğmeyi kullanmasını önerir.
                await deliverSegments(result, bubbleStartedAt: bubbleStartedAt)
                handleTokenBalance(result.tokenBalance)
```

- [ ] **Step 3: Use it in `sendUserVoice()`**

Find (`ChatViewModel.swift:386-397`):

```swift
                let elapsed = Date().timeIntervalSince(bubbleStartedAt)
                let wanted = TypingTiming.duration(forReplyLength: result.reply.count)
                let remaining = wanted - elapsed
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                showsTypingBubble = false
                store?.setTyping(character.id, false)

                messages.append(Message(role: .assistant, content: result.reply))
                handleTokenBalance(result.tokenBalance)
                applyPostReplyEffects(gotPhoto: nil, stored: stored,
                                      serverLevel: result.level, serverProgress: result.levelProgress)
```

Replace with:

```swift
                await deliverSegments(result, bubbleStartedAt: bubbleStartedAt)
                handleTokenBalance(result.tokenBalance)
                applyPostReplyEffects(gotPhoto: nil, stored: stored,
                                      serverLevel: result.level, serverProgress: result.levelProgress)
```

- [ ] **Step 4: Use it in `sendUserPhoto()`**

Find (`ChatViewModel.swift:462-475`):

```swift
                let elapsed = Date().timeIntervalSince(bubbleStartedAt)
                let wanted = TypingTiming.duration(forReplyLength: result.reply.count)
                let remaining = wanted - elapsed
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                showsTypingBubble = false
                store?.setTyping(character.id, false)

                messages.append(Message(role: .assistant, content: result.reply))
                handleTokenBalance(result.tokenBalance)
                // `gotPhoto: nil` — bu bir GELEN fotoğraf. Seviye/ilerleme sunucudan gelir.
                applyPostReplyEffects(gotPhoto: nil, stored: stored,
                                      serverLevel: result.level, serverProgress: result.levelProgress)
```

Replace with:

```swift
                await deliverSegments(result, bubbleStartedAt: bubbleStartedAt)
                handleTokenBalance(result.tokenBalance)
                // `gotPhoto: nil` — bu bir GELEN fotoğraf. Seviye/ilerleme sunucudan gelir.
                applyPostReplyEffects(gotPhoto: nil, stored: stored,
                                      serverLevel: result.level, serverProgress: result.levelProgress)
```

Note: `generatePendingVoice()` (voiceChat: true) and the caption call inside `generatePendingImage()` (imageReactionChat: true) are deliberately left untouched — the server never attaches `replySegments` for those modes (Task 2, Step 2), so `deliverSegments` would just be a more roundabout way of writing the same single-bubble behavior there; not worth the churn in this pass.

- [ ] **Step 5: Build check**

Run: `xcodebuild -project aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -50`

Expected: build succeeds. `TypingTiming` import/usage stays valid since `deliverSegments` still calls `TypingTiming.duration(forReplyLength:)`.

- [ ] **Step 6: Manual end-to-end verification (simulator)**

Run the app in the iOS Simulator (Xcode ▶ Run, or `xcodebuild ... test` if a UI test target exists — none does per Global Constraints, so this is a manual pass):

1. Open a chat with an existing character, send a plain-text message that plausibly invites a dramatic pause (e.g. "I broke the thing you asked me not to touch").
2. Confirm the reply sometimes (not necessarily this exact turn — it's model-improvised) arrives as 2 separate bubbles with a visible "typing…" gap between them, matching `delaySeconds`.
3. Send several more turns; confirm the bot occasionally asks a follow-up question, references something said earlier, or pivots topic — and that a low-level (freshly created) character still shows some romantic/flirty interest rather than none.
4. Ask "how was your day?" and confirm the bot gives a short improvised anecdote rather than declining or repeating its `currentActivity` label verbatim.

Expected: all four behaviors observable within a normal-length test conversation (dramatic pause may take a few tries since it's improvised, not guaranteed every turn — that's by design, see `DRAMATIC_PACING_RULE`).

- [ ] **Step 7: Commit**

```bash
git add aiGirlfriend/ViewModels/ChatViewModel.swift
git commit -m "$(cat <<'EOF'
feat(chat): deliver paced multi-bubble replies in the chat UI

Adds deliverSegments, replacing 3 duplicated single-bubble timing
blocks in send()/sendUserVoice()/sendUserPhoto() — plays back
result.replySegments as separate timed bubbles with a typing
indicator between them when the server sent a [PAUSE:n]-split reply,
falling back to the existing single-bubble behavior otherwise.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```
