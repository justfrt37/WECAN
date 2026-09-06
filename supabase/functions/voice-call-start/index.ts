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
import { callVoiceSettingsFor } from "../_shared/elevenVoiceSettings.ts";
import { requireVoiceEntitlement } from "../_shared/entitlements.ts";
import { V3_AUDIO_TAGS, stripUnknownAudioTags } from "../_shared/voiceTags.ts";
import { NO_ACKNOWLEDGEMENT_RULE } from "../_shared/promptRules.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

import { callLLM } from "../_shared/llm.ts";

const ELEVENLABS_API_KEY = Deno.env.get("ELEVEN_LABS") ?? "";
// TEMP: hardcoded instead of the ELEVENLABS_AGENT_ID secret — CLI account
// isn't an org Owner so `supabase secrets set` is blocked. Move back to
// Deno.env.get("ELEVENLABS_AGENT_ID") once secret write access is sorted.
const ELEVENLABS_AGENT_ID = Deno.env.get("ELEVENLABS_AGENT_ID") ?? "agent_5701kyp1mydkfqnsfn9zw0c2jbqn";

const TOKENS_PER_SECOND = 3;
const MIN_START_BALANCE = 30; // ~10s of call time

// Replaces the old VOICE_TAGS_RULE — Flash v2.5 doesn't support [bracket]
// audio tags, so emotion has to come through word choice/punctuation instead.
// ISO 639-1 code -> display name, matching Plumm/Services/ConversationLanguage.swift's
// `supported` set exactly (tr/en/de/es/fr/it/pt) — client detects the code
// from chat history (or device locale if the chat is empty) and sends it here.
const LANGUAGE_NAMES: Record<string, string> = {
  tr: "Turkish", en: "English", de: "German", es: "Spanish", fr: "French", it: "Italian", pt: "Portuguese",
};

function languageRule(code: string): string {
  const name = LANGUAGE_NAMES[code];
  if (!name) return "";
  return (
    `\n\nLANGUAGE RULE: This call is in ${name} — this was determined from the user's ` +
    "own chat history, not a guess. Speak ONLY in it, never mix in another language, " +
    "never comment on the language itself. Sound like a real person on a phone call " +
    "in that language — warm, colloquial, never robotic."
  );
}

// Emotion/pacing guidance for the voice-call model, rewritten 2026-09-02 when
// the agent moved from eleven_flash_v2 to eleven_v3_conversational.
//
// The old version told the model NOT to use [bracket] tags because Flash can't
// perform them. That was correct for Flash and measured to be correct: fed
// "[whispers] Yaklaş biraz", Flash's own audio transcribes back as "Whispers:
// Yaklaş biraz" — it reads the tag out loud as a word. v3 Conversational
// performs it instead (the transcript comes back with an actual whisper and no
// stray word), so the constraint is gone and the tags are now the point.
//
// LİSTE 2026-09-06'DA DÜZELTİLDİ ve _shared/voiceTags.ts'e taşındı: eski liste
// altı elemanlıydı ve İKİSİ UYDURMAYDI (`[slow]`, `[breathes]`). Tanınmayan
// etiket sese dönüşmüyor, KELİME olarak okunuyor — canlı rapor: mesajın
// ortasındaki `[slow]` "slow" diye telaffuz edildi. Liste artık webhook'un
// stream temizleyicisiyle AYNI kaynaktan geliyor (bkz. voiceTags.ts).

const VOICE_CALL_STYLE_RULE =
  "\n\nVOICE STYLE RULE: This reply will be SPOKEN ALOUD in a real-time phone " +
  "call. Write it the way it should SOUND, not the way it would look in a chat.\n" +
  `AUDIO TAGS: you may use ONLY these exact tags: ${V3_AUDIO_TAGS.map((t) => `[${t}]`).join(", ")}. ` +
  "Copy them character for character. Never invent one, never translate one, " +
  "never inflect one ([slow], [slowly], [yavaş], [laughing], [sad voice] are " +
  "ALL wrong) — an unrecognised tag is read out loud as literal words and ruins " +
  "the call. At most ONE per reply, placed immediately before the words it " +
  "colours; a tag affects roughly the next few words. Most replies need no tag " +
  "at all.\n" +
  "PACE: there is NO tag for speaking slowly or quickly. If you want a slower, " +
  "heavier delivery, write it into the words — commas, ellipses, shorter " +
  "sentences — or use [short pause] / [long pause]. Never invent a pace tag.\n" +
  "NEVER write a laugh, sigh or gasp as letters ('haha', 'hehe', 'ahah', " +
  "'heh', 'hah', 'pff', 'ahh') — those get pronounced as nonsense syllables. " +
  "If you mean a laugh, use [laughs]. This includes the first word of a reply: " +
  "never open on one.\n" +
  "SPEAK, DON'T WRITE: use the contractions and filler words of real speech in " +
  "whatever language you're in, because the voice pronounces exactly what you " +
  "type. In Turkish that means 'biliyom' not 'biliyorum', 'yapıyom' not " +
  "'yapıyorum', 'napıyosun' not 'ne yapıyorsun', 'tmm', 'valla', 'ya', 'yani', " +
  "'işte', 'aynen', 'hadi ya'. Real reactions belong in the words themselves — " +
  "'ayy', 'offf', 'yaa', 'oha', 'aa' — spelled the way they're actually said, " +
  "with the vowel stretched if it's stretched out loud. The same principle " +
  "applies to every other language: use its real spoken shorthand, never the " +
  "written/formal register. Never sound translated, never sound like a news " +
  "reader.\n" +
  "LENGTH: 1-2 sentences (rarely 3). This is a phone call, not a monologue — " +
  "leave room for them to answer.";

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
    // Same atomic-claim guard as voice-call-end: only charge if THIS call is
    // the one that flips active -> ended (two concurrent starts could both
    // pick up the same orphan otherwise).
    const { data: claimed } = await db.from("call_sessions")
      .update({ status: "ended", ended_at: new Date().toISOString() })
      .eq("id", session.id)
      .eq("status", "active")
      .select("id");
    if (!claimed || claimed.length === 0) continue;

    const tokens = Math.round((session.last_checkpoint_seconds ?? 0) * TOKENS_PER_SECOND);
    if (tokens > 0) {
      await db.rpc("charge_tokens", { p_user_id: uid, p_amount: tokens, p_reason: "voice" });
    }
    await db.from("call_sessions")
      .update({ tokens_charged: tokens })
      .eq("id", session.id);
  }
}

// Opener instruction is built here (not baked into the persistent
// systemPrompt) so it only costs tokens on this one-off first-message call,
// not on every turn for the rest of the call. Deliberately gives BEHAVIOR
// to follow, never example lines to recite — a scripted example in the
// prompt gets echoed near-verbatim turn after turn (see chat/index.ts's
// same lesson re: opener habits).
function openerInstruction(recentChatGapMinutes: number | null): string {
  if (recentChatGapMinutes !== null && recentChatGapMinutes <= 10) {
    return (
      `The user was just texting you ${Math.max(1, Math.round(recentChatGapMinutes))} minute(s) ago — this ` +
      "call is a direct continuation of that conversation, not a cold start. Texting-to-calling is a bigger " +
      "conversational moment than another text (more intimate, more immediate) — your opener should register " +
      "that shift, and carry over whatever mood/energy that recent chat was actually in (playful, needy, " +
      "annoyed, sweet, whatever it was) rather than resetting to a generic greeting."
    );
  }
  return (
    "There's no recent chat to continue from — this is a cold call open, like actually picking up the " +
    "phone without knowing exactly what mood you're about to be in. React the way a real person genuinely " +
    "into the caller would when the phone rings/connects — a beat of surprise, warmth, maybe playful or " +
    "teasing depending on your personality — never a flat scripted greeting. Vary the reaction every time, " +
    "never settle into a fixed opening line."
  );
}

// Generates the greeting the Agent speaks first, in-character — uses the
// same system prompt so it matches personality/relationship level. Falls
// back to a plain greeting if Grok fails, since a missing first message
// isn't worth failing the whole call start over.
// Açılış repliği stream DEĞİL, düz metin döndüğü için buradaki temizlik tek
// bir replace ile yapılıyor (bkz. _shared/voiceTags.ts). Canlı gözlem: üretilen
// bir açılış "[surprised but happy]" ile başlamıştı — listede olmayan bir
// etiket, ve telefonu açan kullanıcının duyacağı İLK şey oydu. Tur içi
// cevaplarda da artık aynı liste geçerli; orası stream olduğu için
// voice-call-llm-webhook parça parça temizliyor.
// Açılış repliğinin SERT üst sınırı. Prompt "a few words, not a sentence"
// diyordu ve maxTokens 16'ydı, ama ikisi de tavsiye: model düzenli olarak
// tam cümlelik ("hey, sonunda aradın, seni özledim ya") açılışlar üretiyordu
// ve 16 token Türkçede rahatça 8-10 kelime demek. Telefon açan biri o kadar
// konuşmaz; ilk duyulan şey "alo"ya yakın olmalı. Bu yüzden kelime sayısı
// kodda kesiliyor — prompt'a güvenilmiyor.
//
// [laughs] gibi ses etiketleri KELİME SAYILMAZ: konuşulan söz değiller,
// v3'ün performans yönergesi. Etiketler yerinde bırakılır, kesim yalnızca
// gerçek kelimelere uygulanır.
const OPENER_MAX_WORDS = 5;

function capOpenerWords(text: string): string {
  let words = 0;
  const kept: string[] = [];
  for (const token of text.split(/\s+/).filter(Boolean)) {
    if (/^\[[^\]]+\]$/.test(token)) { kept.push(token); continue; }
    if (words >= OPENER_MAX_WORDS) break;
    words++;
    kept.push(token);
  }
  const capped = kept.join(" ").trim();
  // Kesim cümlenin ortasında kaldıysa sonda asılı kalan virgül/bağlaç
  // noktalaması sesli okunuşta tuhaf bir yarım cümle etkisi yapıyor —
  // sondaki ayırıcıları at, ! ? . ... kalsın.
  return capped.replace(/[,;:\-—]+$/u, "").trim();
}

// Açılış "Noted."/"Anlaşıldı." ile başlıyorsa o replik ÇÖPTİR: model,
// köşeli parantezli açılış yönergesini kullanıcının talimatı sanmış demektir
// (bkz. NO_ACKNOWLEDGEMENT_RULE). Beş kelimelik açılışta bunu kırpmak yerine
// komple fallback'e düşmek doğru — geriye anlamlı bir selam kalmıyor.
const ACK_OPENER =
  /^\s*(?:duly\s+noted|noted|understood|acknowledged|got\s+it|sure\s+thing|of\s+course|anla[sş][ıi]ld[ıi]|tamamd[ıi]r|not\s+al[ıi]nd[ıi])\b/iu;

async function generateFirstMessage(systemPrompt: string, recentChatGapMinutes: number | null): Promise<string> {
  const fallback = "Hey!";
  try {
    const text = (await callLLM(
      [
        { role: "system", content: systemPrompt },
        {
          role: "user",
          content: `[The call just connected. ${openerInstruction(recentChatGapMinutes)} Now say your ` +
            `opening line the way someone actually answers the phone: AT MOST ${OPENER_MAX_WORDS} words, ` +
            "and fewer is better — one or two words is a perfect answer. Think 'alo', 'hey you', " +
            "'heyyy finally', 'oh hi', 'you there?'. NO sentences, no questions longer than two words, " +
            "no explaining, no follow-up. Just the greeting, in character, nothing else. Anything past " +
            `${OPENER_MAX_WORDS} words is cut off mid-air, so do not write it.]`,
        },
      ],
      // 16'dan 12'ye: bu tur zaten 5 kelimeyle sınırlı, fazlası kesilecek
      // çıktı için ödenen token.
      { maxTokens: 12, temperature: 0.9 },
    )).trim();
    if (ACK_OPENER.test(text)) return fallback;
    return capOpenerWords(stripUnknownAudioTags(text)) || fallback;
  } catch {
    return fallback;
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

    // Sesli arama Pro+ / Pro Max hakkı (bkz. _shared/entitlements.ts) — Pro'da
    // yok. Oturum açılmadan ve jeton düşülmeden ÖNCE kontrol edilir.
    const voiceGate = await requireVoiceEntitlement(db, uid);
    if (voiceGate) return json(voiceGate.body, voiceGate.status);

    const body = await req.json();
    const characterId: string = body.characterId;
    const reviewMode: boolean = body.reviewMode === true;
    const language: string = body.language ?? "en";
    if (!characterId) return json({ error: "characterId required" }, 400);
    if (!ELEVENLABS_AGENT_ID) return json({ error: "ELEVENLABS_AGENT_ID not configured" }, 500);

    await finalizeOrphaned(uid);

    const { data: balanceRow } = await db.from("token_balances").select("balance").eq("user_id", uid).maybeSingle();
    if ((balanceRow?.balance ?? 0) < MIN_START_BALANCE) {
      return json({ error: "insufficient_tokens" }, 402);
    }

    // `vibe` yaşamıyor characters'ta bir sütun olarak — builder_selections
    // jsonb'sinin içinde. Eskiden yanlışlıkla düz sütun gibi seçilmeye
    // çalışılıyordu (`vibe` mevcut değil hatası) — sorgu HER SEFERİNDE
    // patlıyor, `character` hep null kalıyor, herkes aynı varsayılan
    // (flirty/Sweet) sese düşüyordu (bkz. kullanıcı raporu — "tüm botlar
    // aynı sesi kullanıyor").
    // system_prompt 2026-09-02'de eklendi. Eskiden seçilmiyordu ve aşağıdaki
    // systemPrompt yalnızca rol/seviye direktifinden kuruluyordu — yani
    // TELEFONDAKİ KARAKTERİN KİMLİĞİ YOKTU: adı, yaşı, mesleği, kişilik
    // tarifi hiçbiri gitmiyordu. ElevenLabs ajanının kendi temel promptu da
    // boş (API'den doğrulandı), dolayısıyla başka bir yerden de gelmiyordu.
    // Sohbet tarafı (chat/index.ts) hep `ch.system_prompt + directive`
    // gönderiyordu; arama tarafı yıllardır jenerik bir personaydı.
    const { data: character } = await db.from("characters")
      .select("personality_role, voice_id, builder_selections, system_prompt").eq("id", characterId).maybeSingle();
    const personalityRole: string = character?.personality_role ?? "flirty";
    const vibe: string = (character?.builder_selections as { vibe?: string } | null)?.vibe ?? "Sweet";

    // Konuşmayı bul ya da oluştur (kullanıcı + karakter) — chat/index.ts'nin
    // AYNI deseni. Client bir conversationId'yi ASLA takip etmiyor (chat
    // tarafında da bu id sunucu tarafında (uid, characterId)'den çözülüyor,
    // istemciye kalıcı bir state olarak hiç dönmüyor) — önceden body'den
    // client-supplied conversationId bekleniyordu, bu YAPISAL olarak hep
    // undefined geliyordu ve call_sessions.conversation_id %100 null
    // kalıyordu (bkz. kullanıcı raporu — sesli arama tabloları conversation
    // ile eşleşmiyor). En güncel olanı al — dupe'lar varsa maybeSingle patlar.
    const { data: convoRows } = await db
      .from("conversations")
      .select("id, relationship_level")
      .eq("user_id", uid)
      .eq("character_id", characterId)
      .order("updated_at", { ascending: false })
      .limit(1);
    let convo = convoRows?.[0];
    if (!convo) {
      // upsert, not insert — conversations(user_id, character_id) UNIQUE
      // (bkz. chat/index.ts'deki aynı düzeltme).
      const ins = await db.from("conversations")
        .upsert({ user_id: uid, character_id: characterId }, { onConflict: "user_id,character_id" })
        .select("id, relationship_level").single();
      convo = ins.data!;
    }
    const conversationId: string = convo.id;
    // Seviye 2026-09-02'ye kadar fetchDirectiveMemoriesBehaviors'a SABİT 1
    // olarak geçiliyordu. Sonuç: kullanıcı seviye 9'da olsa bile telefonda
    // seviye 1 direktifi ("New territory, but you're not shy about it...")
    // geliyordu, ve character_level_overrides tablosundaki gerçek seviye
    // ayarı hiç okunmuyordu. Sohbet ile arama aynı ilişkiyi anlatmıyordu.
    const relationshipLevel: number = typeof convo.relationship_level === "number"
      ? Math.min(10, Math.max(1, convo.relationship_level))
      : 1;

    // Retrieval query text — last 3 prior chat messages for this
    // conversation (a call has no turns of its own yet at start time; the
    // conversation's `messages` table, shared with chat/index.ts, is the
    // only source of "what's currently being discussed"). No prior
    // messages (brand new conversation) → empty string →
    // fetchDirectiveMemoriesBehaviors skips retrieval, no memories block.
    const { data: recentForQuery } = await db
      .from("messages")
      .select("content, created_at")
      .eq("conversation_id", conversationId)
      .order("created_at", { ascending: false })
      .limit(3);
    const memoryQueryText = (recentForQuery ?? []).map((m) => m.content).reverse().join(" ").trim();
    // Recency of the last chat message — feeds the opener instruction
    // (texting-to-calling continuation vs. genuine cold open, see
    // openerInstruction below).
    const recentChatGapMinutes = recentForQuery?.[0]?.created_at
      ? (Date.now() - new Date(recentForQuery[0].created_at).getTime()) / 60_000
      : null;

    const { directive: fetchedDirective, memories, behaviors } =
      await fetchDirectiveMemoriesBehaviors(db, characterId, personalityRole, relationshipLevel, conversationId, memoryQueryText);
    const directive = reviewMode ? REVIEW_DIRECTIVE : fetchedDirective;
    const identity = reviewMode ? "" : (character?.system_prompt ?? "");
    let systemPrompt = identity ? `${identity}\n\n${directive}` : directive;
    systemPrompt += memoriesBlock(memories);
    systemPrompt += behaviorsBlock(behaviors);
    systemPrompt += VOICE_CALL_STYLE_RULE;
    // Açılış ve sessizlik yönergeleri köşeli parantezli `user` mesajı olarak
    // gidiyor; bu kural olmadan karakter "Noted…" diye KONUŞUYOR
    // (bkz. promptRules.ts).
    systemPrompt += NO_ACKNOWLEDGEMENT_RULE;
    systemPrompt += languageRule(language);

    const voiceId = character?.voice_id || elevenVoiceIdFor(personalityRole, vibe, characterId);
    // `speed` stays in the response on purpose — see elevenVoiceSettings.ts.
    // Short version: the agent used to reject a speed override (1008), so it
    // was removed from here; that broke the iOS client's decoding of this
    // response and killed the call even earlier. tts.speed is now allowed on
    // the agent and the value is a constant 1.0.
    const { stability, speed } = callVoiceSettingsFor(personalityRole);
    const firstMessage = await generateFirstMessage(systemPrompt, recentChatGapMinutes);

    const { data: session, error } = await db.from("call_sessions").insert({
      user_id: uid,
      character_id: characterId,
      conversation_id: conversationId,
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
      speed,
      firstMessage,
    });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
