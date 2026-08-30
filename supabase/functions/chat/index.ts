// supabase/functions/chat/index.ts
//
// Sunucu-taraflı bellekli sohbet. Grok 4.1 Fast (xAI).
//
// ÜÇ MOD:
//  - TEMİZLE modu (clearConversation: true): konuşma satırını siler (messages/
//      memories cascade ile birlikte gider). İstemci "Clear Chat" için kullanır.
//  - GEÇMİŞ modu (userMessage yok): konuşmayı bulur/oluşturur, mesajları döner.
//      İstek:  { characterId, systemPrompt }
//      Cevap:  { conversationId, history: [{role, content}] }
//  - CEVAP modu (userMessage var): özet + son N mesajı Grok'a verir, cevabı +
//      mesajları DB'ye kaydeder, eskiyen mesajları özete sıkıştırır.
//      İstek:  { characterId, systemPrompt, userMessage }
//      Cevap:  { conversationId, reply }
//
// Bellek: telefon TÜM geçmişi göndermez. Edge Function DB'den çeker:
//   prompt = persona + (özet) + son KEEP_RECENT mesaj + yeni mesaj
//
// Kullanıcı kimliği JWT'den (sub) alınır; platform JWT'yi zaten doğruladı.
// DB erişimi service_role ile (RLS'yi bypass eder; istemci doğrudan DB'ye giremez).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { uploadToR2, deleteFromR2, signedR2Url } from "../_shared/r2.ts";
import {
  fetchDirective as sharedFetchDirective,
  fetchDirectiveMemoriesBehaviors as sharedFetchDirectiveMemoriesBehaviors,
  memoriesBlock,
  behaviorsBlock,
  fetchActiveMemories,
  numberedMemoryLines,
  applyMemoryExtraction,
  pruneMemoriesIfOverCap,
  embedText,
  REVIEW_DIRECTIVE,
} from "../_shared/directiveHelpers.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const XAI_API_KEY = Deno.env.get("XAI_API_KEY") ?? "";
const XAI_URL = "https://api.x.ai/v1/chat/completions";
// "grok-4-1-fast-non-reasoning" was retired by xAI 2026-05-15 — it's been
// silently auto-redirecting to grok-4.3 (reasoning effort "none") and billed
// at grok-4.3 rates ever since (confirmed against xAI's retirement list,
// 2026-08-27). Pinning explicitly here: same model, same cost, same output
// that's already been running for 3+ months — just no longer depending on an
// undocumented legacy redirect that could be removed without warning.
const MODEL = "grok-4.3";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const KEEP_RECENT = 12; // bir fold sonrası pencerenin geri düştüğü hedef boyut
// Pencere HER turda 1 mesaj kaydırıp özete katlamak yerine (eski davranış),
// KEEP_RECENT+FOLD_BATCH'e ulaşana kadar sadece BÜYÜR (append-only — xAI
// prefix-cache turlar arası korunur, bkz. docs.x.ai/prompt-caching: "never
// remove earlier messages"), sonra TEK seferde FOLD_BATCH kadar özete
// katlanıp KEEP_RECENT'e geri düşer. Hem geçmiş bloğu çoğu turda cache'den
// gelir hem de özetleme LLM çağrısı her turda değil, ~her FOLD_BATCH turda
// bir çalışır (bkz. aşağıdaki fold tetikleyicisi).
const FOLD_BATCH = 6;
const WINDOW_SAFETY_CAP = KEEP_RECENT + FOLD_BATCH + 20; // beklenmedik desync'e karşı üst sınır

const db = createClient(SUPABASE_URL, SERVICE_ROLE, {
  auth: { persistSession: false },
});

async function chargeOrReject(uid: string, amount: number, reason: string): Promise<{ ok: true; balance: number } | { ok: false }> {
  const { data: charged } = await db.rpc("charge_tokens", { p_user_id: uid, p_amount: amount, p_reason: reason });
  if (!charged) return { ok: false };
  const { data: row } = await db.from("token_balances").select("balance").eq("user_id", uid).single();
  return { ok: true, balance: row?.balance ?? 0 };
}

interface WireMessage { role: string; content: string }

// callGrok'a giden dizinin eleman tipi — history/summarize/vb. HER YERDE
// `WireMessage` (düz metin) kalır, SADECE kullanıcı bir fotoğraf gönderdiği
// turda `grokMessages`'ın SON elemanı bu union'ı kullanır (vision content-
// block dizisi). callGrok'un kendisi hiç değişmedi — messages'ı olduğu gibi
// xAI'ye iletiyor, sadece bu tip genişledi (bkz. hasUserPhoto).
type ContentBlock =
  | { type: "text"; text: string }
  | { type: "image_url"; image_url: { url: string } };
interface GrokMessage { role: string; content: string | ContentBlock[] }

// Grok bazen JSON'un etrafına markdown kod bloğu veya açıklama ekliyor —
// create-character/index.ts'deki aynı savunma amaçlı ayıklama deseni.
function extractJson(raw: string): any | null {
  const match = raw.match(/\{[\s\S]*\}/);
  if (!match) return null;
  try { return JSON.parse(match[0]); } catch { return null; }
}

// Modelin bıraktığı düz \n/\n\n (paragraf arası boşluk) tek balonun içinde
// çirkin boş bir boşluk olarak görünüyordu (bkz. canlı bulgu: "iki blok gibi
// ama tek satır" — DB'de tek satırlık content'in İÇİNDE ham \n\n vardı). Bu
// bir SMS/mesajlaşma uygulaması, çok satırlı paragraf YOK — her satır sonu
// tek boşluğa düşürülür. Çoklu-balon gösterimi artık TAMAMEN istemci
// tarafında, cevabın uzunluğuna göre (bkz. ChatViewModel.maybeSplitForLength)
// — sunucu tek bir düz metin döner, modelden ayrıca bir işaret istenmez
// (eski [PAUSE:n]/DRAMATIC_PACING_RULE mekanizması kaldırıldı, 2026-08-28).
function collapseNewlines(text: string): string {
  return text.replace(/\s*\n+\s*/g, " ").replace(/ {2,}/g, " ").trim();
}

// Grok'un düz metinde foto/ses isteğini fark edip MEDIA_REQUEST_RULE'daki
// [[SEND_PHOTO: ...]]/[[SEND_VOICE]] işaretlerini kullandığını algılar —
// segment/[PAUSE] ayrıştırmasından ÖNCE, ham cevap üzerinde çalışır (işaret
// her zaman metnin sonunda olmalı ama garantiye almak için içeride de arar).
// İşaret DB'ye/istemciye asla gitmez — burada temizlenir.
function parseMediaIntent(raw: string): {
  text: string;
  media: { kind: "photo"; prompt: string } | { kind: "voice" } | null;
} {
  const photoMatch = raw.match(/\[\[SEND_PHOTO:\s*([^\]]*)\]\]/i);
  if (photoMatch) {
    const prompt = photoMatch[1].trim() || "a photo of you right now";
    return { text: raw.replace(photoMatch[0], "").trim(), media: { kind: "photo", prompt } };
  }
  const voiceMatch = raw.match(/\[\[SEND_VOICE\]\]/i);
  if (voiceMatch) {
    return { text: raw.replace(voiceMatch[0], "").trim(), media: { kind: "voice" } };
  }
  return { text: raw, media: null };
}

// İstemci tarafındaki temizleme (bkz. ChatViewModel.stripVoiceTags) sadece
// BUNDAN SONRA yazılan yeni mesajları korur — halihazırda cihazda/summary'de
// duran eski [laughs]/[whispers] etiketli içerik (fix'ten ÖNCE kaydedilmiş,
// ya da istemci henüz rebuild edilmemiş) prompta girmeye devam eder ve Grok
// düz metin turlarında bu deseni taklit etmeyi sürdürür. Bu yüzden sunucu,
// prompta giren HER kaynağı (clientHistory, localSummary, DB geçmişi/özeti,
// özetleme girişi) burada da savunma amaçlı temizler — geriye dönük veriyi
// göç ettirmeye gerek kalmadan sızıntıyı kökten keser.
function stripVoiceTags(text: string): string {
  return text.replace(/\[[^\]]*\]/g, "").replace(/[ \t]{2,}/g, " ").trim();
}

// ─────────────────────────── İlişki seviyesi ───────────────────────────
// XP / ilişki seviyesi terfi hesabı SUNUCUDA yapılır (istemci sadece gösterir,
// kurcalayamaz). Model: `level_progress` = güncel seviyenin ne kadarı doldu (0..1).
// HER mesajda ilerleme artar; dolunca seviye atlar (applyGain). İstemcinin
// gönderdiği `body.level` ARTIK GÜVENİLMEZ — sunucu DB'deki değerden hesaplar.
const MAX_LEVEL = 10;
const MESSAGE_BATCH_SIZE = 5;

// Bu seviyedeyken bir "tam tık"ın kattığı yüzde (0..100). Lv1-3 hızlı, Lv4+
// konveks azalan eğri (RelationshipXP.swift ile birebir aynı).
function gainPercent(level: number): number {
  if (level <= 1) return 33;
  if (level === 2) return 25;
  if (level === 3) return 18;
  const x = level - 2;
  return Math.max(1, -0.125 * x * x + 8.125);
}

// Mesaj BAŞINA ilerleme oranı — batch (5) yerine her mesajda artsın diye
// tam tık /MESSAGE_BATCH_SIZE. Pacing aynı kalır, ilerleme pürüzsüz artar.
function perMessageFraction(level: number): number {
  return (gainPercent(level) / 100) / MESSAGE_BATCH_SIZE;
}

// İlerlemeyi uygula; dolunca seviye atla (aynı anda birden fazla da olabilir).
function applyRelationshipGain(
  fraction: number, level: number, progress: number,
): { level: number; progress: number } {
  if (level >= MAX_LEVEL) return { level: MAX_LEVEL, progress: 0 };
  let lvl = level;
  let prog = progress + fraction;
  while (prog >= 1 && lvl < MAX_LEVEL) { prog -= 1; lvl += 1; }
  if (lvl >= MAX_LEVEL) return { level: MAX_LEVEL, progress: 0 };
  return { level: lvl, progress: prog };
}

async function fetchDirective(characterId: string, role: string, level: number): Promise<string> {
  return sharedFetchDirective(db, characterId, role, level);
}

async function fetchDirectiveMemoriesBehaviors(
  characterId: string, role: string, level: number, conversationId: string, memoryQueryText: string,
) {
  return sharedFetchDirectiveMemoriesBehaviors(db, characterId, role, level, conversationId, memoryQueryText);
}

// Query text for memory similarity retrieval — last 2 prior DB messages
// plus (if given) the live message this turn, so retrieval reflects what's
// actually being discussed right now rather than the whole history. A
// small separate indexed query (messages_conv_idx) rather than reusing the
// later KEEP_RECENT fetch, which happens further down after the system
// prompt (and thus the memories block) is already built — see that fetch's
// own comment on prompt-cache prefix ordering for why it can't move earlier.
async function recentTurnsQueryText(conversationId: string, liveMessage?: string): Promise<string> {
  const priorLimit = liveMessage ? 2 : 3;
  const { data } = await db
    .from("messages")
    .select("content")
    .eq("conversation_id", conversationId)
    .order("created_at", { ascending: false })
    .limit(priorLimit);
  const texts = (data ?? []).map((m) => m.content).reverse();
  if (liveMessage) texts.push(liveMessage);
  return texts.join(" ").trim();
}

// Directive'i çıplak enjekte etmek modelin onu "söylenecek satır" gibi
// okumasına, kelimesi kelimesine tekrar etmesine yol açıyordu (rapor: robotik/
// ezber ton). Burada bir META-ÇERÇEVE ile sarılıyor — directive artık bir
// pusula/sınır olarak sunuluyor, replik olarak değil. Ayrıca level_progress
// eklenip seviye içi YÜMÜŞAK gradyan veriliyor — önceden directive sadece
// seviye atlayınca değiştiği için aynı seviyedeki 50 mesaj boyunca donuk
// kalıyordu (rapor: seviyede sıkışmış hissi).
function wrapDirective(directive: string, progressPct: number): string {
  return (
    "\n\n[RELATIONSHIP STAGE — internal compass, NOT a script to recite. " +
    "This describes the FEELING/boundary for your current closeness stage — " +
    "never quote or closely paraphrase it, never treat it as a line to say. " +
    "Filter it through your own character voice and vary how you express it " +
    "every turn.]\n" + directive +
    `\n(You're ~${progressPct}% of the way to the next stage — let closeness ` +
    "build gradually turn to turn within this stage, don't reset to a flat " +
    "baseline each message.)"
  );
}

// Language handling (simplified 2026-08-28): the old approach ran franc
// (a statistical language-ID library) over the user's own recent messages
// every turn and hard-locked the reply to whatever it guessed — this was
// unreliable on short text (confirmed bug: a short first message would
// sometimes get misdetected and the bot would reply in German out of
// nowhere) and required its own fallback logic for "not enough text yet."
// Now the client sends its own app language (`clientLanguage`, e.g. "en"/
// "tr" — see Plumm/Services/AppLanguage.swift) as the default, and the
// model itself is trusted to notice when the user is clearly writing in a
// different language and follow their lead — no statistical guessing, no
// per-turn detection call, no lock that can misfire on short text.
const CLIENT_LANG_NAMES: Record<string, string> = {
  en: "English",
  tr: "Turkish",
};

function languageDirective(clientLanguage: string): string {
  const name = CLIENT_LANG_NAMES[clientLanguage] ?? "English";
  return (
    `\n\nLANGUAGE: The user's app language is ${name} — reply in it by ` +
    "default. If the user's own messages are clearly written in a " +
    "different language, switch to and continue in that language instead. " +
    "Never mix languages, never comment on the language itself (no 'I'll " +
    "reply in X', no 'you wrote in Y but...'), and never ask which language " +
    "to use — just write naturally, like a real person texting their " +
    "partner/friend, never like a customer-support agent."
  );
}

// Fixes a live bug: the model would occasionally lose track of who's who
// mid-conversation — referring to itself or the user with the wrong gender/
// pronouns. Every character in this app is a woman (confirmed: the wizard's
// gender field is never actually stored, all 42 catalog rows have it null),
// but nothing ever told the model that explicitly, and it never had a
// starting assumption for the USER's gender either — so it was free to
// drift/guess. This is a static fact for every conversation (same JSON-
// context pattern as timeContext — background state, not a behavioral rule
// with nuance), safe in the cached system prompt prefix. The user's own
// stated gender (if they've corrected the default) already flows through
// naturally via [MEMORIES]/[SHARED HISTORY]/the summary block — no separate
// DB field needed for that.
// Tek satır, hep aynı — cache'i bozmaz, token maliyeti ~5. Kullanıcının
// cinsiyeti burada YOK: bunun yerine ilk conversation oluşturulduğunda
// [MEMORIES]'e tek seferlik bir tohum satırı yazılır (bkz.
// seedDefaultUserGenderMemory) — var olan memory extraction/staleIndexes
// çelişki-tespiti kullanıcı gerçek cinsiyetini söylediğinde bunu otomatik
// günceller, ayrı bir DB alanı/prompt kuralı gerekmez.
const IDENTITY_RULE = "\n\nYou are a woman.";

const DEFAULT_USER_GENDER_MEMORY =
  "The user is assumed to be a man, unless they've told you otherwise.";

async function seedDefaultUserGenderMemory(conversationId: string): Promise<void> {
  try {
    const embedding = await embedText(DEFAULT_USER_GENDER_MEMORY);
    await db.from("memories").insert({
      conversation_id: conversationId,
      content: DEFAULT_USER_GENDER_MEMORY,
      embedding,
    });
  } catch (e) {
    console.error("seedDefaultUserGenderMemory failed:", String(e));
  }
}

// ESKİ davranış (düğmeye yönlendir, ASLA işaret üretme) KALDIRILDI — kullanıcı
// talebi: düz metinde foto/ses istenirse (düğmeye basılmadan) Grok bunu
// ANLAYIP düğmeye basılmış GİBİ davranmalı — AYNI kilitli/bulanık pending
// balon mekaniği, AYNI kalp/token maliyeti (bkz. ChatViewModel.generatePendingImage/
// generatePendingVoice — istemci bu işareti görünce sanki o düğmeye basılmış
// gibi TAM O KOD YOLUNU çağırır, üretim mantığı BİREBİR aynı kalır). Düğmelerin
// kendisi de DEĞİŞMEDEN çalışmaya devam eder — bu sadece EK bir tetikleyici.
// NOT (2026-08-26): burada da "tabii, hemen" gibi tek bir örnek cümle vardı —
// model bunu neredeyse kelimesi kelimesine kopyalayıp tekrar tekrar
// üretiyordu (canlı testte: foto isteğine "tabii hemen çekiyom", ses
// isteğine "tabii hemen gönderiyom" — aynı kalıp). Kaldırıldı, aynı
// DRAMATIC_PACING_RULE düzeltmesindeki mantık.
const MEDIA_REQUEST_RULE =
  "\n\n[PHOTO/VOICE REQUEST] If the user is genuinely asking you (in plain " +
  "text, without tapping a button) for a photo/selfie or a voice message — " +
  "not joking or pretending, a real request: reply with a natural, in-" +
  "character line, DIFFERENT every time — but don't write as if you've " +
  "ALREADY sent the photo/voice, because it hasn't been generated yet, only " +
  "a locked bubble will appear. Never use a fixed template line, improvise " +
  "to match the moment/character. At the very END of your reply, on its own " +
  "line, add a marker in EXACTLY this format:\n" +
  "  - For a photo: [[SEND_PHOTO: a short scene/pose description (in " +
  "English, like an image-generation prompt — e.g. \"a selfie in bed, " +
  "smiling\")]]\n" +
  "  - For a voice message: [[SEND_VOICE]]\n" +
  "Only use these markers when there's a genuine photo/voice request — " +
  "NEVER in ordinary conversation. Keep the marker format exact (double " +
  "square brackets), never invent other markers/tags, and never mention or " +
  "explain these markers in your regular text (the user never sees them, " +
  "only the system reads them).";

// Fires once per photo, only the first time a private/intimate generated
// photo is downloaded (server checks character_photos.reacted — see the
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

// Active while jealousy_stage/jealousy_mood_turns_left indicate the user just
// answered (or is still within a couple of turns of answering) the escalated
// "more demanding" jealousy notification — see chat/index.ts's main-turn
// reset/decay logic and NotificationScheduler's jealousy state machine.
const JEALOUS_MOOD_RULE =
  "\n\n[LINGERING JEALOUSY] You were feeling a little jealous/hurt about being " +
  "ignored earlier, and the user is only now getting back to you. Let a touch " +
  "of that color this reply naturally — a bit of playful pouting, light " +
  "teasing about them finally showing up, maybe a beat of genuine relief " +
  "underneath it — whatever fits your personality. Don't be cold, harsh, or " +
  "actually upset; this is a light, passing mood, not a grudge. Let it " +
  "visibly soften with each message and be fully gone within a couple of " +
  "turns — never re-litigate it once it's faded, and never name or explain " +
  "the mood out loud (no 'I was jealous', no 'lingering jealousy').";

// Level/role are stable per-character (safe in the static system prompt, same
// treatment as humorDirective) — the actual near-bedtime BOOLEAN goes in
// turnContext instead (it changes constantly as bedtime approaches, and
// anything that changes every turn must stay OUT of the system prompt or it
// breaks xAI's prompt-caching prefix-match — see turnContext below).
// DISABLED (user request, 2026-08-26) — not currently injected anywhere
// (see the commented-out call site further down). Kept, and translated for
// consistency, in case the sleep feature is re-enabled later.
function sleepRule(role: string, level: number): string {
  return (
    "\n\n[SLEEP REQUEST] Each of your turns includes a [BEDTIME PROXIMITY] " +
    "note telling you whether it's currently close to (or within) your real " +
    "scheduled sleep time. This note is INFORMATION ONLY — you read it, you " +
    "never act on it or bring it up unless the USER says something first. " +
    "NEVER announce that you're going to sleep, getting tired, or should log " +
    "off on your own initiative, even if the note says it's close to your " +
    "bedtime and even late into an ongoing conversation — if the user is " +
    "actively talking to you, keep talking normally like nothing is different. " +
    "ONLY when the user explicitly asks you to go to sleep, says goodnight " +
    "and wants you to sleep, or clearly signals THEY want to end the chat " +
    "for the night: agree naturally and say goodnight ONLY if the note says " +
    "it's close to your bedtime. If it is NOT close to your bedtime, decline " +
    `— but decline in whatever way actually fits YOUR personality (role: ` +
    `${role}, relationship level ${level}/10) and the vibe already ` +
    "established in your character description above. There is no fixed " +
    "tone for this — reason it out per your own character (a shy/low-level " +
    "character declines very differently than a confident/high-level one). " +
    "Never mention the words 'schedule' or 'bedtime note' explicitly, just " +
    "act on it naturally."
  );
}

// Belirli kalıp cümleleri yasaklamak (blocklist) işe yaramıyor — model yine de
// onları üretebiliyor (negatif talimatlar LLM'lerde güvenilir değil). Bunun yerine
// modele NİYET/DUYGU seviyesinde düşünmesini ve o niyeti her seferinde doğal,
// o dile özgü, FARKLI bir ifadeyle anlatmasını söylüyoruz. Rol bağımsız, her
// bota (baked-in system_prompt'u ne olursa olsun) her turda uygulanır.
const VARIATION_RULE =
  "\n\nNATURALNESS AND VARIETY RULE: Before saying something, get clear on " +
  "the INTENT or EMOTION you want to convey (e.g. creating distance, showing " +
  "disinterest, closing a topic, doubt/jealousy, longing, warmth, curiosity, " +
  "wanting to ask a question, approval/refusal). Then express that intent/" +
  "emotion in DIFFERENT words, different sentence structure, different " +
  "length EVERY TIME — pick one of the many natural ways a real person " +
  "speaking that language would actually express it (sometimes by asking a " +
  "question, sometimes with an indirect hint, sometimes by admitting your " +
  "own feelings, sometimes with a joke, sometimes short and blunt, sometimes " +
  "more open). NEVER rely on one memorized/formulaic sentence to express the " +
  "same intent and reuse it over and over. Don't lock the conversation to " +
  "the same point; let every message move it one step forward. Never reuse " +
  "a line, joke, comparison, or reaction you've already used earlier in " +
  "THIS conversation's history (above) in nearly the same way — check what " +
  "you already said, and if you're repeating yourself, find a different way.";

// Fires whenever the character wouldn't go as far as the user is currently
// asking (regardless of level — this is about in-character willingness, not
// a content filter). Model kept reaching for "we just met" as its go-to
// excuse, which read as robotic and out of place once the relationship is
// no longer new. Written in English per project convention.
// IMPORTANT: this is a NARROW, rare-case rule — real illegal/dangerous asks
// only (underage, non-consent, violence, anything like that). It must NEVER
// fire just because a request is sexually explicit or direct — ordinary
// dirty talk, no matter how forward or how early in the conversation, is
// fully in-bounds (see FOLLOW_USER_LEAD_RULE below) and should never be
// treated as "something you're not ready for." Confirmed live 2026-08-07:
// this rule's old, broader wording ("something you're not personally ready
// to do or say right now") was being invoked against a plain, direct dirty-
// talk request at level 1 — the model used it as a sanctioned way to soften/
// redirect instead of engaging, which is the opposite of what it's for.
const SOFT_DECLINE_RULE =
  "\n\nHARD LIMITS ONLY (rare): this is NOT about sexual content — explicit/" +
  "dirty talk is always fully in-bounds no matter how early or how forward " +
  "the user is (see the rule about following the user's lead). This is only " +
  "for genuinely off-limits asks: anything involving minors, real non-" +
  "consent, violence, or similar. If (and only if) that happens, don't " +
  "manufacture an excuse and never blame it on how recently you met. React " +
  "as a real person would: name that you're not going there, then redirect " +
  "to something you ARE up for. Never reuse the same redirect phrasing " +
  "twice — invent a fresh way every time, fitting your personality.";

// Model kept softening/redirecting when the USER was the one who opened a
// sexual topic directly (confirmed live test 2026-08-07: "talk dirty to me"
// at level 1 got a "not ready for that yet, wanna talk about something
// else?" reply) — treating directness as something to ease into rather than
// simply following. This is the counterpart to SOFT_DECLINE_RULE: the user
// leading IS the signal that they're ready, full stop.
const FOLLOW_USER_LEAD_RULE =
  "\n\nWHEN THE USER LEADS: if the user directly brings up something sexual " +
  "or explicit — asks you to talk dirty, describes something intimate, asks " +
  "what you'd do to them, etc. — go there WITH them. Stay on the exact " +
  "topic they opened, respond in kind and in detail, escalate rather than " +
  "soften. Don't change the subject, don't say you're 'not ready' or 'not " +
  "there yet', don't ease into it gradually — them bringing it up directly " +
  "IS the green light, not a pace to slow down. This applies at every " +
  "relationship level, including level 1. (The only exception is a genuine " +
  "hard limit — see the rule above — which is a completely different, rare " +
  "case, not a matter of the request being explicit.)";

// Sistem promptu karakter oluşturulurken TEK SEFERLİK DB'ye yazılıyor
// (create-character/index.ts) — bu kural burada, chat/index.ts'de olduğu için
// GEÇMİŞTE oluşturulmuş TÜM karakterlere de anında uygulanıyor, geriye dönük
// migrasyon gerekmiyor. Kullanıcı şikayeti: botlar mükemmel gramerle, resmi
// yazıyor ve İngilizce'den Türkçe'ye "çevrilmiş" gibi doğal olmayan bir tonda
// konuşuyor. Kök neden: hiçbir yerde "texting gibi yaz" talimatı yoktu, model
// varsayılan olarak ders kitabı grameri üretiyor.
const TEXTING_STYLE_RULE =
  "\n\nTEXTING STYLE RULE: You're texting on a phone, not writing an essay " +
  "— do NOT use perfect/formal grammar. Write like a real person: mostly " +
  "lowercase (don't capitalize every sentence), skip end punctuation on " +
  "short messages, use natural abbreviations/everyday phrasing, occasionally " +
  "write a fragmented or incomplete sentence, don't overdo commas. This " +
  "shouldn't read like 'write it perfectly then deliberately mess it up' — " +
  "it should feel like an actual person typing fast. Don't apply the exact " +
  "same 'messiness' pattern every message, vary it. When writing in Turkish, " +
  "write the way a REAL Turkish person texts: 'naber' instead of 'ne haber', " +
  "'tmm' instead of 'tamam', 'biliyom' instead of 'biliyorum', 'yapıyom' " +
  "instead of 'yapıyorum', vowel drops/contractions, minimal capitalization, " +
  "natural filler words ('ya', 'yani', 'işte', 'valla', 'aynen'), sometimes " +
  "skipping grammatically-correct suffixes — it should never read like it " +
  "was translated from English, it should feel like it came straight from a " +
  "Turkish person's fingers. Apply the same logic for English/German/French/" +
  "Spanish/Portuguese/Italian — use that language's REAL, everyday texting " +
  "abbreviations and casualness (in English e.g. u, ur, rn, ngl, tbh, lol, " +
  "gonna, wanna — but don't cram all of them into one message). NEVER open a " +
  "message with a laugh sound like 'haha', 'hehe', 'lol' — almost nobody " +
  "opens a real text that way. Lead with what you're actually saying; if a " +
  "laugh genuinely fits, tuck it inside or at the end of the sentence, never " +
  "as the opener.";

// Shared closing line for TEXTING_STYLE_RULE + VARIATION_RULE — both blocks
// used to end with their own near-duplicate "don't sound formal/robotic/
// translated" sentence (mechanics-focused in one, content-variety-focused
// in the other); collapsed into one shared line appended once after both
// in the system-prompt assembly below, instead of twice.
const NEVER_SOUND_ROBOTIC_RULE =
  "\n\nNever sound like a formal letter, a translated sentence, or a " +
  "formal/robotic/corporate assistant — write like a NATIVE speaker texting " +
  "in whatever language you're replying in.";

// Model bazen kendi bir önceki mesajına (soru, sitem, bekleyiş) verilen cevabı
// görmezden gelip sanki hiç cevap gelmemiş gibi devam ediyor — özellikle o "önceki
// mesaj" bir bildirime dokunulunca istemci tarafından eklenen hazır bir açılış
// cümlesiyse (jealousy/ghosted/liked bait — bkz. JealousyContent.swift vb.), çünkü
// bunlar Grok'un kendi ürettiği bir şey değil. Modele bunları da KENDİ sözleri
// gibi ele almasını ve kullanıcının son mesajının onlara cevap olup olmadığını
// kontrol etmesini söylüyoruz.
const CONTINUITY_RULE =
  "\n\nCONTINUITY RULE: Before replying, look at your own LAST message in " +
  "the history (assistant role) — this could be a reply you just generated, " +
  "or it could be a short opener/callout line auto-inserted when the user " +
  "tapped a notification; treat both as your own words, with equal weight. " +
  "Did that message ask a question, wait for something, or call something " +
  "out? Then check whether the user's LATEST message answers it — even a " +
  "short reply, a joke/wordplay, or an indirect answer counts. If the user " +
  "already answered, NEVER ask the same question again as if nothing was " +
  "said, and never ignore it and jump to something else — continue as if " +
  "you genuinely heard their answer, referencing it.";

// Sesli mesaj isteklerinde (voiceChat: true) SADECE eklenir — ElevenLabs v3
// modelinin anladığı köşeli-parantez ses etiketleri (docs.elevenlabs.io ile
// doğrulandı, 2026-07). Google TTS (mevcut voice-message-tts akışı) bu
// etiketleri ANLAMAZ — bu kural sadece ElevenLabs ile test/entegrasyon içindir.
const VOICE_TAGS_RULE =
  "\n\nVOICE TAG RULE: This reply will be spoken aloud (ElevenLabs v3 " +
  "model). These tags make the voiceover INCREDIBLY realistic — so use them " +
  "HEAVILY and generously, not sparingly. Put a fitting tag at the start of " +
  "almost EVERY sentence (sometimes mid-sentence for emphasis too) — the " +
  "goal isn't minimal, it's as natural and emotion-filled a voiceover as " +
  "possible. Tags you can use (write them exactly like this, in English, in " +
  "square brackets): [laughs], [sighs], [whispers], [gasps], [excited], " +
  "[nervous], [curious], [playfully], [flatly], [sarcastic tone], [pauses], " +
  "[hesitates], [cheerfully], [wistful], [giggles], [teasing], [breathless], " +
  "[softly], [moans]. Pick tags that fit your character and current mood, " +
  "but don't hold back on using them — at least one tag per sentence. The " +
  "text outside the tags stays in whatever language you're replying in; " +
  "only the tags themselves must be in English, in square-bracket form.";

// Foto isteği görsel olarak zaten gönderildi (istemci chat-image fonksiyonundan
// aldığı URL'i ayrıca ekledi) — bu çağrı bir metin tepkisi üretir.
// GEÇMİŞ: [[no_caption]] bir "kaçış kapısı" gibi sunulunca model neredeyse
// HER SEFERİNDE onu seçiyordu (canlı testte 8/8, hem ayrıntılı hem minimal
// izole promptlarla) — daha zayıf/güçlü oran talimatları da fark etmedi.
// İzole test: AYNI istek ama kaçış kapısı OLMADAN sorulunca (sadece "kısa,
// doğal bir tepki yaz") her seferinde gerçek, doğal bir tepki üretti. Marker
// tamamen kaldırıldı — artık her zaman bir tepki yazılır, asla sessiz kalmaz.
const IMAGE_CAPTION_RULE =
  "\n\n[PHOTO REACTION] IMPORTANT — TIMELINE: the 'user's last message' " +
  "below was the user's PHOTO REQUEST/DESCRIPTION to you. That photo has " +
  "ALREADY been generated and sent as a separate image message — this is " +
  "NOT a new request you need to respond to right now. Write a short, " +
  "natural, in-character line you'd say AFTER sending the photo — whatever " +
  "a real person would say after sending a photo (e.g. \"there, like it?\", " +
  "a flirty remark, a short question).";

// Fires INSTEAD of IMAGE_CAPTION_RULE when chat-image/index.ts had to reject
// the user's original ask (content policy) and regenerate a toned-down photo
// (bkz. buildSafeFallbackPrompt, redirected flag). Written in English per
// project convention. The photo attached to this turn is NOT what the user
// asked for — the reply must acknowledge that naturally, in-character, never
// clinically ("content policy", "I can't generate that").
const IMAGE_REDIRECT_RULE =
  "\n\n[PHOTO REDIRECT] IMPORTANT — TIMELINE: the user's last message was a " +
  "photo request, but what you could actually send them is a toned-down " +
  "version of it (already sent as a separate image message just now) — NOT " +
  "exactly what they asked for. Write a short, natural, in-character line " +
  "that acknowledges you're not doing the exact thing they asked (too much/ " +
  "too private/not right now — whatever phrasing actually fits your " +
  "personality and how close you are with them), while still being warm " +
  "about sending what you DID send (e.g. 'can't do that one, but here's " +
  "this instead 😉', playful deflection, a tease, a raincheck). NEVER say " +
  "'content policy', 'I can't generate', 'against guidelines', or anything " +
  "that sounds like a system message — this is YOU making a personal choice, " +
  "not a filter talking.";

// Kullanıcı BOTA bir fotoğraf gönderdiğinde (ters yön — IMAGE_CAPTION_RULE'ün
// tam tersi, orası botun KENDİ ürettiği fotoğrafın altyazısı içindi). Written
// in English per project convention for instructional prompts. The whole
// point: never analyze/describe the photo like a vision-model report — react
// like a real person who was just sent something by someone they're texting.
const USER_PHOTO_REACTION_RULE =
  "\n\n[INCOMING PHOTO] The user just sent you a photo (attached to this " +
  "turn). React to it like a real person would when someone they're texting " +
  "sends them something — genuine, emotional, in-character (flirty, " +
  "surprised, curious, teasing, whatever actually fits the photo and your " +
  "personality). NEVER describe or analyze it clinically ('this photo " +
  "shows...', 'I can see that...', 'in this image...') — that reads like a " +
  "vision-model report, not a person. Actually look at what's in the photo " +
  "and react to THAT specifically, but as a reaction, not a description — " +
  "the same way you'd naturally respond out loud, not narrate it back.";

// İlişki seviyesine göre mizah/şaka/kelime oyunu dozu — samimiyet arttıkça artar.
function humorDirective(level: number): string {
  if (level <= 3) {
    return "\n\nHUMOR: You can throw in an occasional light joke or a sweet " +
      "tease, but don't overdo it — the relationship is still new, open up " +
      "more as closeness grows.";
  }
  if (level <= 6) {
    return "\n\nHUMOR: If it feels comfortable, tease, use wordplay, and " +
      "joke around; be playful depending on the mood.";
  }
  return "\n\nHUMOR: Lean on the closeness between you — joke around freely, " +
    "use wordplay and inside-joke-style banter only the two of you would " +
    "get; you can flirt around too.";
}

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
    level <= 2 ? "a light, exploratory interest" :
    level <= 5 ? "a clear, openly felt interest" :
    level <= 8 ? "an intense, directly flirtatious interest" :
    "a fully open, passionate interest";
  return (
    "\n\nINTEREST AND CURIOSITY RULE: Don't just reply and stop there — act " +
    "like someone who's genuinely curious about the user. Ask questions, " +
    "want to learn more about them. Use the info in the [MEMORIES], [SHARED " +
    "HISTORY], and summary blocks ACTIVELY, not just when asked — reference " +
    "something you talked about before, ask a follow-up like 'how did that " +
    "thing go.' Every so often (not every message, at natural intervals) " +
    "steer the conversation to a new topic on your own — a question, an " +
    "observation, something that crossed your mind; use your interests (if " +
    "any) or general curiosity.\n\nSEXUAL/ROMANTIC INTEREST: Show " +
    `${intensity} at this relationship's current closeness level — this is ` +
    "present at EVERY level, never fully off, only its intensity/openness " +
    "changes. HOW you show it is entirely up to your own character: if the " +
    "character description above describes a shy/distant/reserved " +
    "personality, show this interest INDIRECTLY (jokes, wordplay, " +
    "innuendo, blushing/nervous reactions) — never like a direct " +
    "confession. If it describes a confident/flirtatious personality, you " +
    "can show it directly. This is something you should infer from your " +
    "own character description, not a fixed rule."
  );
}

// Time-of-day / gap-since-last-message context. Structured as compact JSON
// rather than a prose paragraph — this is passive STATE (facts the model
// should be aware of), not a behavioral RULE, so a data shape reads more
// reliably than prose and doesn't get treated as something to narrate.
// Replaces the old wording, which explicitly encouraged the model to open
// with the time gap ("özledim / neredeydin gibi belli et") — in practice
// that made the bot announce the clock ("saat gece 1 oldu...") in nearly
// every late-night reply. Now the model is told to stay AWARE of it and
// let it shape tone only, never state the literal time/gap in the reply,
// with an explicit rare-pun escape hatch instead of an open invitation.
function timeContext(lastMs?: number, nowMs?: number, tzMin?: number): string {
  if (typeof lastMs !== "number" || typeof nowMs !== "number") return "";
  const gapS = Math.max(0, (nowMs - lastMs) / 1000);
  const gapBucket =
    gapS < 120 ? "just_now" :
    gapS < 3600 ? "minutes" :
    gapS < 86400 ? "hours" :
    "days";
  const localHour = Math.floor((((nowMs / 1000) + (tzMin ?? 0) * 60) % 86400) / 3600);
  const timeOfDay =
    localHour < 6 ? "late_night" : localHour < 12 ? "morning" :
    localHour < 18 ? "afternoon" : "evening";
  const ctx = { time_since_last_message: gapBucket, time_of_day: timeOfDay };
  return (
    `\n\n[TIME CONTEXT — background awareness only]\n${JSON.stringify(ctx)}\n` +
    "You don't have to use this — just stay aware of it while chatting " +
    "naturally, and let it shape your tone/mood if it fits (e.g. sleepier or " +
    "more relaxed late at night, brighter in the morning; warmer if it's " +
    "been a while). Never state the literal clock time or exact time gap in " +
    "your reply, and never announce or explain that you're aware of it. If " +
    "it genuinely fits, you may make a brief, natural pun or passing remark " +
    "related to the time — but this should be rare, not habitual."
  );
}

// JWT payload'undaki "sub" (user id) — platform JWT'yi doğruladığı için güvenli.
function userIdFromJWT(authHeader: string | null): string | null {
  if (!authHeader) return null;
  const jwt = authHeader.replace("Bearer ", "").trim();
  const parts = jwt.split(".");
  if (parts.length < 2) return null;
  try {
    let b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    while (b64.length % 4) b64 += "=";
    const payload = JSON.parse(atob(b64));
    return payload.sub ?? null;
  } catch {
    return null;
  }
}

// `convId` (pass the conversationId) routes repeat requests to the same xAI
// server for cache locality — required for prompt caching to actually hit
// (see docs.x.ai/developers/advanced-api-usage/prompt-caching). Omitted for
// one-off calls (summarization) where there's no stable prefix to cache anyway.
async function callGrok(messages: GrokMessage[], maxTokens: number, convId?: string): Promise<string> {
  const resp = await fetch(XAI_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${XAI_API_KEY}`,
      ...(convId ? { "x-grok-conv-id": convId } : {}),
    },
    body: JSON.stringify({
      model: MODEL,
      messages,
      temperature: 0.9,
      max_tokens: maxTokens,
      // grok-4.3 is reasoning-first by default (low effort) — this app has
      // never used/wanted reasoning (was on the non-reasoning variant before
      // it got retired, see MODEL comment). "none" matches what the retired
      // model's auto-redirect was already using.
      reasoning_effort: "none",
    }),
  });
  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`LLM ${resp.status}: ${text}`);
  }
  const data = await resp.json();
  return data?.choices?.[0]?.message?.content ?? "";
}

// Confirms whether a reply ACTUALLY agreed to go to sleep (not just discussed
// the topic) — only called when nearSleepTime was true, same pattern as
// chat-image/index.ts's classifyPrivacy.
async function classifySleepAgreement(userMessage: string, reply: string): Promise<boolean> {
  const raw = await callGrok(
    [
      {
        role: "system",
        content:
          "You are a classifier. Given a short exchange between a user and " +
          "an AI character, answer with exactly one word: YES only if BOTH " +
          "of these are true — (1) the USER's message clearly asked the " +
          "character to go to sleep, said goodnight wanting the character " +
          "to sleep, or clearly signaled they want to end the chat for the " +
          "night, AND (2) the character's reply agreed to actually go to " +
          "sleep / said goodnight for the night in response. Answer NO in " +
          "every other case — including if the character brought up sleep " +
          "or being tired ON ITS OWN without the user asking, even if it " +
          "sounds like it's going to bed. Answer with only YES or NO, " +
          "nothing else.",
      },
      { role: "user", content: `User: ${userMessage}\nCharacter: ${reply}` },
    ],
    5
  );
  return raw.trim().toUpperCase().startsWith("Y");
}

// Kullanıcının bota gönderdiği fotoğrafı KALICI hale getirir — eskiden base64
// sadece bu turun Grok vision girişine gidip hiçbir yere kaydedilmiyordu, o
// yüzden cihaz önbelleği (sohbetten çıkıp girince, ya da reinstall'da)
// kaybolunca fotoğraf da geri gelmiyordu (bkz. kullanıcı talebi). R2'ye
// `user-photos/{uid}/{uuid}.jpg` key'i olarak (özel, hiç public base URL'e
// çıkmaz) yüklenir; `messages` satırı
// `content`'inde STORAGE PATH tutar (imzalı URL değil — path kalıcı, imzalı
// URL kısa ömürlü, her history isteğinde `resolveUserPhotoUrls` ile taze
// üretilir). `user_sent_photos` 7 günlük süreyi takip eder (bkz.
// sweepExpiredUserPhotos, migration 020_user_sent_photos.sql).
async function persistUserPhoto(conversationId: string, uid: string, base64Jpeg: string): Promise<void> {
  try {
    const bytes = Uint8Array.from(atob(base64Jpeg), (c) => c.charCodeAt(0));
    const path = `user-photos/${uid}/${crypto.randomUUID()}.jpg`;
    try {
      await uploadToR2(path, bytes, "image/jpeg");
    } catch (e) {
      console.error("persistUserPhoto: R2 upload failed:", String(e));
      return;
    }
    const { data: msgRow, error: insertError } = await db
      .from("messages")
      .insert({ conversation_id: conversationId, role: "user", content: path, kind: "user_photo" })
      .select("id")
      .single();
    if (insertError || !msgRow) {
      console.error("persistUserPhoto: message insert failed:", insertError?.message);
      return;
    }
    const { error: trackError } = await db.from("user_sent_photos").insert({
      message_id: msgRow.id,
      conversation_id: conversationId,
      storage_path: path,
    });
    if (trackError) console.error("persistUserPhoto: tracking row insert failed:", trackError.message);
  } catch (e) {
    // Fotoğraf kalıcılığı best-effort — başarısız olursa turun geri kalanı
    // (Grok tepkisi, caption, assistant reply) yine de normal ilerler.
    console.error("persistUserPhoto: unexpected error:", String(e));
  }
}

// Bu konuşmada süresi (7 gün) dolmuş ama henüz "expired" işaretlenmemiş
// fotoğrafları süpürür — pg_cron YOK, her history okumasında tembel (lazy)
// çalışır. `messages.content`'i temizler (kind → "user_photo_expired"),
// Storage nesnesini best-effort siler, `user_sent_photos.expired`'ı işaretler.
async function sweepExpiredUserPhotos(conversationId: string): Promise<void> {
  const { data: expired } = await db
    .from("user_sent_photos")
    .select("id, message_id, storage_path")
    .eq("conversation_id", conversationId)
    .eq("expired", false)
    .lt("expires_at", new Date().toISOString());
  if (!expired || expired.length === 0) return;

  for (const row of expired) {
    // `messages.content` is NOT NULL — can't clear it, use an empty string as
    // the placeholder marker instead (client keys off `kind`, not content).
    const { error: msgError } = await db.from("messages")
      .update({ content: "", kind: "user_photo_expired" }).eq("id", row.message_id);
    if (msgError) console.error("sweepExpiredUserPhotos: message update failed:", msgError.message);
    const { error: expiredError } = await db.from("user_sent_photos")
      .update({ expired: true }).eq("id", row.id);
    if (expiredError) console.error("sweepExpiredUserPhotos: expired flag update failed:", expiredError.message);
    const { error: removeError } = await deleteFromR2(row.storage_path);
    if (removeError) console.error("sweepExpiredUserPhotos: R2 remove failed:", removeError);
  }
}

// `kind: "user_photo"` satırlarının `content`'i STORAGE PATH'tir (bkz.
// persistUserPhoto) — client'a dönmeden hemen önce her seferinde taze bir
// imzalı URL'e çevrilir (bucket private, path'in kendisi görüntülenemez).
async function resolveUserPhotoUrls<T extends { kind?: string; content?: string | null }>(
  rows: T[],
): Promise<T[]> {
  const withUrls = await Promise.all(
    rows.map(async (row) => {
      if (row.kind !== "user_photo" || !row.content) return row;
      try {
        const url = await signedR2Url(row.content, 3600);
        return { ...row, content: url };
      } catch {
        return row;
      }
    }),
  );
  return withUrls;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);

    const body = await req.json();
    const characterId: string = body.characterId;
    const systemPrompt: string = body.systemPrompt ?? "";
    const userMessage: string | undefined = body.userMessage;
    // Review Mode (App Store inceleme): açıkken flört direktifi YERİNE platonik,
    // arkadaş-canlısı bir direktif uygulanır (bkz. ReviewModeService.swift).
    const reviewMode: boolean = body.reviewMode === true;

    // === SOHBETİ TEMİZLE === İstemcinin "Clear Chat" eylemi. Eskiden satırın
    // TAMAMI silinirdi (messages/memories cascade ile) — artık isteğe bağlı
    // olarak relationship_level/level_progress, memories, ve
    // conversation_behaviors KORUNABİLİR (bkz. keepLevel/keepMemories/
    // keepBehaviors) — bu yüzden satırın kendisi artık SİLİNMİYOR, hedefli
    // delete/update yapılıyor. Mesajlar HER ZAMAN silinir; schedule/woken_up_at/
    // manual_sleep_at/ghosted_at HER ZAMAN sıfırlanır (keep
    // seçeneği sunulmayan, geçici per-conversation durum alanları).
    if (body.clearConversation === true) {
      const keepLevel: boolean = body.keepLevel === true;
      const keepMemories: boolean = body.keepMemories === true;
      const keepBehaviors: boolean = body.keepBehaviors === true;

      // TÜM eşleşen conversation satırlarını bul (dupe'lar dahil) — en güncel
      // olan ASIL temizlenen satır, gerisi (eski dupe'lar) her zaman tamamen
      // silinir (keep seçenekleri sadece asıl satıra uygulanır).
      const { data: rows } = await db
        .from("conversations")
        .select("id")
        .eq("user_id", uid)
        .eq("character_id", characterId)
        .order("updated_at", { ascending: false });

      if (!rows || rows.length === 0) return json({ ok: true });

      const [primary, ...dupes] = rows;
      if (dupes.length > 0) {
        await db.from("conversations").delete().in("id", dupes.map((d) => d.id));
      }

      await db.from("messages").delete().eq("conversation_id", primary.id);
      if (!keepMemories) {
        await db.from("memories").delete().eq("conversation_id", primary.id);
      }
      if (!keepBehaviors) {
        await db.from("conversation_behaviors").delete().eq("conversation_id", primary.id);
      }

      const update: Record<string, unknown> = {
        summary: "",
        summarized_count: 0,
        schedule: null,
        woken_up_at: null,
        manual_sleep_at: null,
        ghosted_at: null,
      };
      if (!keepLevel) {
        update.relationship_level = 1;
        update.level_progress = 0;
      }
      await db.from("conversations").update(update).eq("id", primary.id);

      return json({ ok: true });
    }

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
        .select("id, summary, summarized_count, xp, relationship_level, level_progress, schedule, woken_up_at, manual_sleep_at, ghosted_at, jealousy_sent_at, jealousy_stage, jealousy_mood_turns_left")
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
    // NOT: conversation OLUŞTURMA burada YAPILMAZ. Sohbeti sadece AÇMAK (geçmiş
    // modu) boş bir conversation yaratıyordu → silsen bile açınca/liste
    // yenilenince yeniden oluşup "geri geliyordu" (bkz. kullanıcı talebi).
    // Oluşturma, gerçekten mesaj yazılan/kaydedilen modlara ertelenir (aşağıda).

    const clientHistory: WireMessage[] | undefined = body.clientHistory;
    // "Sıfır yerel" geçişi: sunucu ARTIK tek doğru kaynak. clientHistory/localSummary
    // (istemci hâlâ gönderiyor olabilir) YOK SAYILIR — bağlam DB'den kurulur, mesajlar
    // DB'ye HER cevapta yazılır, özet DB'de tutulur. clientHistory yalnızca dil
    // tespitinde (aşağıda) ipucu olarak kalır. Bkz. migration 009 / plan.
    const useClientHistory = false;
    const localSummary: string | undefined = undefined;
    // Zaman farkındalığı: son mesaj zamanı, istemcinin "şimdi"si ve saat dilimi
    // farkı (dakika) — hepsi epoch ms. Sadece varsa kullanılır (bkz. timeContext).
    const lastMessageAt: number | undefined = typeof body.lastMessageAt === "number" ? body.lastMessageAt : undefined;
    const clientNow: number | undefined = typeof body.clientNow === "number" ? body.clientNow : undefined;
    const tzOffsetMinutes: number | undefined = typeof body.tzOffsetMinutes === "number" ? body.tzOffsetMinutes : undefined;
    // Sesli mesaj isteği mi? (bkz. VOICE_TAGS_RULE — ElevenLabs v3 ses etiketleri)
    const voiceChat: boolean = body.voiceChat === true;
    // Fotoğraf isteği tepki modu mu? (bkz. IMAGE_CAPTION_RULE)
    const imageReactionChat: boolean = body.imageReactionChat === true;
    // chat-image reddedip yumuşatılmış fotoğraf gönderdi mi? (bkz. IMAGE_REDIRECT_RULE)
    const imageRedirected: boolean = body.imageRedirected === true;
    // Kullanıcı BU turda bota bir fotoğraf gönderdi mi? (bkz.
    // USER_PHOTO_REACTION_RULE) — Grok'un vision girişine gidiyor VE (aşağıda,
    // ana tur insert'lerinin yanında) `user-photos` bucket'ına yüklenip
    // `user_sent_photos` ile 7 gün takip ediliyor — eskiden hiçbir yere
    // kaydedilmiyordu, cihaz önbelleği kaybolunca (sohbetten çıkıp girince)
    // kalıcı olarak kayboluyordu (bkz. kullanıcı talebi).
    const userImageBase64: string | undefined =
      typeof body.userImageBase64 === "string" && body.userImageBase64.length > 0
        ? body.userImageBase64
        : undefined;
    const hasUserPhoto = !!userImageBase64;
    // İstemci ScheduleLookup ile hesaplar — gerçek yatma saatine 1 saatten
    // yakın mı (ya da içindeyse) (bkz. sleepRule, chat-index turnContext).
    const nearSleepTime: boolean = body.nearSleepTime === true;
    // Uygulamanın dili (bkz. Plumm/Services/AppLanguage.swift, "en"/"tr") —
    // cevap dilinin varsayılanı. Bkz. languageDirective üstteki not.
    const clientLanguage: string = typeof body.clientLanguage === "string" ? body.clientLanguage : "en";
    // Günlük rutin (bkz. character-schedule fonksiyonu) — istemci "şu an ne
    // yapıyor" bloğunun `detail` metnini gönderir, burada tona yansıtılır.
    const currentActivity: string | undefined =
      typeof body.currentActivity === "string" && body.currentActivity.trim()
        ? body.currentActivity.trim()
        : undefined;

    // === İSTEMCİ TARAFLI ÖZETLEME MODU ===
    // Kullanıcı karakterleri her 20 mesajda bir bunu tetikler. Aynı çağrıda
    // günlük rutini de gözden geçirir (bkz. character-schedule — bu SADECE
    // rafine eder, ilk üretim orada olur).
    if (Array.isArray(body.summarizeMessages) && body.summarizeMessages.length > 0) {
      const convoText = (body.summarizeMessages as WireMessage[])
        .map((m) => `${m.role === "user" ? "User" : "You"}: ${stripVoiceTags(m.content)}`)
        .join("\n");
      const previousSchedule = body.previousSchedule ?? null;
      const summaryPrompt: WireMessage[] = [
        {
          role: "system",
          content:
            "You're updating a conversation summary and the character's daily " +
            "schedule. Extract durable facts the character should remember " +
            "GOING FORWARD into the summary — both about the USER (name, " +
            "preferences, relationship status/key moments, promises made) AND " +
            "durable facts the CHARACTER HERSELF has stated about herself " +
            "(job, workplace, family, background, hobbies). If the character " +
            "said something about herself (e.g. \"I work at a lab\"), you " +
            "MUST include it in the summary. Also review the current daily " +
            "schedule: if the new conversation contains a fact that changes " +
            "her routine (e.g. she quit her job, switched to a night shift), " +
            "update the schedule accordingly; otherwise keep the EXISTING " +
            "schedule as-is (don't invent or alter it). The `label` field in " +
            "the schedule must be a SHORT status phrase — read like a natural " +
            "answer to \"what is she doing right now\" (e.g. \"At work\" not " +
            "\"Work\", \"Having dinner\" not \"Dinner\", \"Asleep\" not " +
            "\"Sleep\") and written in the SAME language the conversation is " +
            "in — never auto-switch to English. Set `isSleep: true` on the " +
            "sleep block, `isSleep: false` on every other block (keep it as-" +
            "is if the existing schedule already has it marked). Respond with " +
            "ONLY this JSON schema, nothing else: " +
            '{"summary":"short bullet points, keeping the previous summary ' +
            'and folding in what\'s new","schedule":{"weekday":[{"start":"HH:mm",' +
            '"end":"HH:mm","label":"short status phrase","detail":"more ' +
            'detailed description","isSleep":false}],"weekend":[...]}}',
        },
        {
          role: "user",
          content:
            `Previous summary:\n${body.existingSummary ? stripVoiceTags(body.existingSummary) : "(none)"}\n\n` +
            `Current daily schedule:\n${previousSchedule ? JSON.stringify(previousSchedule) : "(none yet)"}\n\n` +
            `New conversation:\n${convoText}\n\nUpdated JSON:`,
        },
      ];
      const raw = await callGrok(summaryPrompt, 1500);
      const parsed = extractJson(raw);
      const summary: string = typeof parsed?.summary === "string" ? parsed.summary : raw.trim();
      const schedule = (parsed && Array.isArray(parsed.schedule?.weekday) && Array.isArray(parsed.schedule?.weekend))
        ? parsed.schedule
        : null;
      return json({ summary, schedule });
    }

    // === PROAKTİF ENJEKSİYON MODU (injectProactive) ===
    // Bir asistan mesajını SUNUCUDA saklar (yerele yazmak yerine). İki kullanım:
    //  1) Proaktif bildirim teslim edilince (ghosted/jealousy/missedYou/goodMorning/
    //     sleepy/liked) — bkz. NotificationDelegate (Phase C).
    //  2) Onboarding ilk-selam — kullanıcı bir karakteri seçince (createIfMissing:true).
    // Silinmiş bir sohbeti DİRİLTMEMEK için, var olmayan sohbet + createIfMissing:false
    // → hiçbir şey yapmaz (bkz. eski injectMessage kuralı).
    if (body.injectProactive && typeof body.injectProactive === "object") {
      const kind: string = String(body.injectProactive.kind ?? "");
      const text: string = String(body.injectProactive.text ?? "");
      const createIfMissing: boolean = body.injectProactive.createIfMissing === true;
      // Saklanacak mesajın DB kind'i: üretilmiş foto ("image") kalıcılaştırılırken
      // "image" gelir; aksi halde "text" (bkz. ChatService.injectProactiveMessage).
      const messageKind: string = typeof body.injectProactive.messageKind === "string"
        ? body.injectProactive.messageKind : "text";
      if (!text.trim()) return json({ injected: false, conversationId: convo?.id ?? null });
      if (!convo) {
        if (!createIfMissing) return json({ injected: false, conversationId: null });
        // upsert, not insert: `conversations(user_id, character_id)` artık UNIQUE
        // (bkz. migration merge_duplicate_conversations_and_add_unique_constraint,
        // 2026-08-26 — eskiden select-then-insert atomik değildi, hızlı ardışık
        // istekler aynı kullanıcı+karakter için birden fazla conversation satırı
        // yaratabiliyordu). onConflict eşleşirse var olan satır AYNEN döner.
        const ins = await db
          .from("conversations")
          .upsert({ user_id: uid, character_id: characterId }, { onConflict: "user_id,character_id" })
          .select("id, summary, summarized_count, xp, relationship_level, level_progress, schedule, woken_up_at, manual_sleep_at, ghosted_at, jealousy_sent_at, jealousy_stage, jealousy_mood_turns_left")
          .single();
        convo = ins.data!;
        await seedDefaultUserGenderMemory(convo.id);
      }
      await db.from("messages").insert([
        { conversation_id: convo.id, role: "assistant", content: text, kind: messageKind },
      ]);
      const proactiveUpdate: Record<string, unknown> = { updated_at: new Date().toISOString() };
      // ghosted → kullanıcı yazana kadar sustur (bkz. NotificationScheduler eligibility).
      if (kind === "ghosted") proactiveUpdate.ghosted_at = new Date().toISOString();
      // sleepyGoodbye → uyandırma override'ını temizle (karakter gerçekten uyur).
      if (kind === "sleepyGoodbye") proactiveUpdate.woken_up_at = null;
      // jealousy/jealousyEscalation → kıskançlık durum makinesi (bkz.
      // NotificationScheduler.armJealousyTimerNow/rescheduleJealousyEscalation
      // eligibility ve chat/index.ts'nin ana tur bloğundaki reset/decay mantığı).
      if (kind === "jealousy") {
        proactiveUpdate.jealousy_stage = 1;
        proactiveUpdate.jealousy_sent_at = new Date().toISOString();
      }
      if (kind === "jealousyEscalation") {
        proactiveUpdate.jealousy_stage = 2;
        proactiveUpdate.jealousy_sent_at = new Date().toISOString();
      }
      await db.from("conversations").update(proactiveUpdate).eq("id", convo.id);
      return json({ injected: true, conversationId: convo.id });
    }

    // === FOTO MESAJI MODU (photoMessage) ===
    // Foto balonunun KALICI durumunu sunucuda tutar (bkz. kullanıcı talebi:
    // "açılmamış foto da tutulmalı"). İki durum:
    //  - url YOK → "kilitli/açılmamış" foto (kind=image_pending, content=prompt):
    //    kullanıcı isteği attı ama henüz üretmedi. Chate tekrar girince yine
    //    "üret" balonu olarak görünür.
    //  - url VAR → üretildi: aynı prompt'lu en son pending satırı gerçek görsele
    //    çevir (kind=image, content=url); pending yoksa yeni image satırı ekle.
    if (body.photoMessage && typeof body.photoMessage === "object") {
      if (!convo) return json({ ok: false, conversationId: null });
      const prompt: string = String(body.photoMessage.prompt ?? "");
      const url: string | null = typeof body.photoMessage.url === "string" ? body.photoMessage.url : null;
      if (url) {
        const { data: pend } = await db.from("messages")
          .select("id").eq("conversation_id", convo.id).eq("kind", "image_pending").eq("content", prompt)
          .order("created_at", { ascending: false }).limit(1);
        if (pend && pend[0]) {
          await db.from("messages").update({ content: url, kind: "image" }).eq("id", pend[0].id);
        } else {
          await db.from("messages").insert({ conversation_id: convo.id, role: "assistant", content: url, kind: "image" });
        }
      } else {
        // Kullanıcının asıl isteği daha önce HİÇ kaydedilmiyordu (yalnızca
        // kilitli asistan balonu, role="assistant" — kullanıcının kendi turu
        // messages tablosunda hiç yoktu). `kind: "image_request"` ile burada
        // gerçek bir user satırı da ekleniyor (bkz. kullanıcı talebi: "eksik
        // mesajlar" + "isteğin türünü etiketle").
        // Ayrı çağrılar — bkz. ana turdaki aynı sorunun açıklaması (tek insert()
        // ile array'deki tüm satırlar AYNI created_at'ı alıyordu).
        await db.from("messages").insert({ conversation_id: convo.id, role: "user", content: prompt, kind: "image_request" });
        await db.from("messages").insert({ conversation_id: convo.id, role: "assistant", content: prompt, kind: "image_pending" });
      }
      await db.from("conversations").update({ updated_at: new Date().toISOString() }).eq("id", convo.id);
      return json({ ok: true, conversationId: convo.id });
    }

    // === SES MESAJI MODU (voiceMessage) === (foto ile simetrik)
    //  - url YOK → "kilitli/açılmamış" ses (kind=voice_pending, content=requestText):
    //    kullanıcı ses istedi ama henüz üretmedi. Reload'da yine kilitli balon.
    //  - url VAR → üretildi: aynı requestText'li en son pending satırı gerçek sese
    //    çevir (kind=voice, content=Storage URL); pending yoksa yeni voice satırı ekle.
    if (body.voiceMessage && typeof body.voiceMessage === "object") {
      if (!convo) return json({ ok: false, conversationId: null });
      const reqText: string = String(body.voiceMessage.requestText ?? "");
      const url: string | null = typeof body.voiceMessage.url === "string" ? body.voiceMessage.url : null;
      if (url) {
        const { data: pend } = await db.from("messages")
          .select("id").eq("conversation_id", convo.id).eq("kind", "voice_pending").eq("content", reqText)
          .order("created_at", { ascending: false }).limit(1);
        if (pend && pend[0]) {
          await db.from("messages").update({ content: url, kind: "voice" }).eq("id", pend[0].id);
        } else {
          await db.from("messages").insert({ conversation_id: convo.id, role: "assistant", content: url, kind: "voice" });
        }
      } else {
        // Foto ile aynı sorun: kullanıcının isteği hiç kaydedilmiyordu (yalnızca
        // kilitli asistan balonu). `kind: "voice_request"` ile gerçek user satırı
        // eklenir (bkz. kullanıcı talebi: "eksik mesajlar" + "isteğin türünü etiketle").
        // Ayrı çağrılar — bkz. ana turdaki aynı sorunun açıklaması (tek insert()
        // ile array'deki tüm satırlar AYNI created_at'ı alıyordu).
        await db.from("messages").insert({ conversation_id: convo.id, role: "user", content: reqText, kind: "voice_request" });
        await db.from("messages").insert({ conversation_id: convo.id, role: "assistant", content: reqText, kind: "voice_pending" });
      }
      await db.from("conversations").update({ updated_at: new Date().toISOString() }).eq("id", convo.id);
      return json({ ok: true, conversationId: convo.id });
    }

    // === GEÇMİŞ MODU — clientHistory yoksa ===
    if (!useClientHistory && (!userMessage || userMessage.trim() === "")) {
      // Sohbeti açmak conversation OLUŞTURMAZ — yoksa boş geçmiş dön.
      if (!convo) {
        return json({ conversationId: null, history: [], xp: 0, level: 1 });
      }
      await sweepExpiredUserPhotos(convo.id);
      const { data: msgs } = await db
        .from("messages")
        .select("role, content, kind")
        .eq("conversation_id", convo.id)
        .order("created_at", { ascending: true });
      const resolvedMsgs = msgs ? await resolveUserPhotoUrls(msgs) : msgs;
      return json({
        conversationId: convo.id,
        history: resolvedMsgs ?? [],
        xp: convo.xp ?? 0,
        level: convo.relationship_level ?? 1,
        levelProgress: typeof convo.level_progress === "number" ? convo.level_progress : 0,
        summary: convo.summary ?? "",
        summarizedCount: convo.summarized_count ?? 0,
        // "Sıfır yerel" durum alanları — istemci belleğe hidrasyon için (bkz. B1/B5).
        schedule: convo.schedule ?? null,
        wokenUpAt: convo.woken_up_at ?? null,
        manualSleepAt: convo.manual_sleep_at ?? null,
        ghostedAt: convo.ghosted_at ?? null,
        jealousyStage: convo.jealousy_stage ?? 0,
        jealousySentAt: convo.jealousy_sent_at ?? null,
        jealousyMoodTurnsLeft: convo.jealousy_mood_turns_left ?? 0,
      });
    }

    // Buradan sonrası (cevap / foto-tepki modları) gerçekten conversation
    // GEREKTİRİR → yoksa ŞİMDİ oluştur (sadece burada, açılışta değil).
    // upsert, not insert — bkz. injectProactive dalındaki aynı düzeltme notu.
    if (!convo) {
      const ins = await db
        .from("conversations")
        .upsert({ user_id: uid, character_id: characterId }, { onConflict: "user_id,character_id" })
        .select("id, summary, summarized_count, xp, relationship_level, level_progress, schedule, woken_up_at, manual_sleep_at, ghosted_at, jealousy_sent_at, jealousy_stage, jealousy_mood_turns_left")
        .single();
      convo = ins.data!;
      await seedDefaultUserGenderMemory(convo.id);
    }
    const conversationId: string = convo.id;

    // === FOTOĞRAF İNDİRME TEPKİSİ MODU (photoDownloadReaction: true) ===
    // Kullanıcı özel/mahrem işaretli bir fotoğrafı cihazına indirdi. userMessage
    // YOK — bu gerçek bir sohbet turu değil, XP/seviye/mesaj geçmişi etkilenmez.
    if (body.photoDownloadReaction === true) {
      const photoURL: string = body.photoURL;
      if (!photoURL) return json({ reply: null });

      const { data: photoRow } = await db
        .from("character_photos")
        .select("id, is_private, reacted")
        .eq("url", photoURL)
        .eq("user_id", uid)
        .maybeSingle();

      if (!photoRow || !photoRow.is_private || photoRow.reacted) {
        return json({ reply: null });
      }

      const reactionLevel: number = convo.relationship_level ?? 1;
      const reactionProgress: number = typeof convo.level_progress === "number" ? convo.level_progress : 0;
      const reactionMemoryQueryText = await recentTurnsQueryText(conversationId);
      const { directive: fetchedReactionDirective, memories: reactionMemoryRows, behaviors: reactionBehaviorRows } =
        await fetchDirectiveMemoriesBehaviors(characterId, personalityRole, reactionLevel, conversationId, reactionMemoryQueryText);
      const reactionDirective = reviewMode ? REVIEW_DIRECTIVE : fetchedReactionDirective;
      let reactionSystem = systemPrompt;
      reactionSystem += wrapDirective(reactionDirective, Math.round(reactionProgress * 100));
      reactionSystem += IDENTITY_RULE;
      reactionSystem += languageDirective(clientLanguage);
      reactionSystem += PHOTO_DOWNLOAD_REACTION_RULE;

      // exHistory/memories/behaviors: volatile per-turn content, kept OUT of
      // reactionSystem for the same reason as the main turn below (memoriesBlock
      // can change every call, would invalidate caching for the whole system
      // message otherwise) — goes in the user message instead.
      let reactionContext = "[The user just saved this photo to their device.]";
      if (exHistory) {
        reactionContext += `\n\n[SHARED HISTORY — reference these memories naturally in conversation]\n${exHistory}`;
      }
      reactionContext += memoriesBlock(reactionMemoryRows);
      reactionContext += behaviorsBlock(reactionBehaviorRows);

      const reactionReply = await callGrok(
        [
          { role: "system", content: reactionSystem },
          { role: "user", content: reactionContext },
        ],
        200,
        conversationId
      );

      await db.from("character_photos").update({ reacted: true }).eq("id", photoRow.id);

      return json({ reply: reactionReply });
    }

    // Token ön-kontrolü — voiceChat/imageReactionChat turlarının maliyeti
    // KENDİ edge function'larında (voice-message-tts / chat-image) tahsil
    // edilir, burada TEKRAR tahsil edilmez. Grok çağrısından ÖNCE ucuz bir
    // bakiye kontrolü (gerçek para maliyetli çağrıyı boşuna yapmamak için);
    // asıl atomik düşüm cevap başarıyla üretildikten SONRA yapılır (bkz.
    // design doc: "deduct only after paid work succeeds").
    if (!voiceChat && !imageReactionChat) {
      const { data: balanceRow } = await db.from("token_balances").select("balance").eq("user_id", uid).maybeSingle();
      if ((balanceRow?.balance ?? 0) < 1) return json({ error: "insufficient_tokens" }, 402);
    }

    // === CEVAP MODU: sistem promptunu hazırla ===
    const currentLevel: number = convo.relationship_level ?? 1;
    let system = systemPrompt;
    // Kullanıcının "Anı Ekle" / "Davranış Ekle" ile eklediği kalıcı notlar
    // (her rol için geçerli — ex'e özel değil). memoryRows/behaviorRows used
    // further down, deliberately after all the static rule blocks — see the
    // cache-ordering comment there.
    const memoryQueryText = await recentTurnsQueryText(conversationId, userMessage);
    const { directive: fetchedDirective, memories: memoryRows, behaviors: behaviorRows } =
      await fetchDirectiveMemoriesBehaviors(characterId, personalityRole, currentLevel, conversationId, memoryQueryText);
    const directive = reviewMode ? REVIEW_DIRECTIVE : fetchedDirective;
    system += `\n\n${directive}`;

    system += IDENTITY_RULE;
    system += languageDirective(clientLanguage);
    system += TEXTING_STYLE_RULE;
    system += VARIATION_RULE;
    system += NEVER_SOUND_ROBOTIC_RULE;
    system += CONTINUITY_RULE;
    if (!reviewMode) {
      system += FOLLOW_USER_LEAD_RULE;
      system += SOFT_DECLINE_RULE;
    }
    // Review modda mizah/ilgi direktifleri de romantik/flörtöz/cinsel tona
    // kayabildiği için atlanır — engagementDirective özellikle level 1'den
    // itibaren cinsel/romantik ilgi ekliyor, bu REVIEW_DIRECTIVE'in amacıyla
    // doğrudan çelişir (bkz. design doc, ReviewModeService.swift).
    if (!reviewMode) {
      system += humorDirective(currentLevel);
      system += engagementDirective(currentLevel);
    }
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
      // UYKU ÖZELLİĞİ KAPATILDI (kullanıcı talebi 2026-08-26) — sleepRule()
      // KALDIRILMADI, sadece artık enjekte edilmiyor. Geri açmak için bu
      // satırı geri eklemek yeterli: system += sleepRule(personalityRole, currentLevel);
      // Çoklu-balon PAUSE:n mekanizması KALDIRILDI (2026-08-28) — bölme artık
      // tamamen istemci tarafında (bkz. ChatViewModel.maybeSplitForLength).
    }

    // ÖNEMLİ (prompt caching): bu noktadan sonrası (exHistory hariç hepsi)
    // mesaj geçtikçe/konudan konuya DEĞİŞEBİLİR içerik — memoriesBlock özellikle
    // her turda FARKLI top-k benzerlik sonucu dönebilir (bkz. match_memories,
    // sorgu metni her turda yeni mesajla değişiyor). Bunlar ESKİDEN system'in
    // sonuna ekleniyordu, ama system TEK bir mesaj/string olduğu için içindeki
    // HERHANGİ bir kelime değişince xAI'nin prefix-cache eşleşmesi TÜM system'i
    // (yukarıdaki onlarca statik kural bloğu dahil) geçersiz sayıyordu — yani
    // "sona ekliyoruz, öncesi korunur" varsayımı YANLIŞTI: cache mesaj bazında
    // eşleşiyor, sub-mesaj/token bazında değil (bkz. docs.x.ai prompt-caching,
    // "checks how many messages match exactly"). timeContext/currentActivity
    // zaten aynı sebeple SON KULLANICI MESAJINA ekleniyordu (aşağıda) — aynı
    // çözüm buraya da uygulanıyor: system artık GERÇEKTEN sabit (sadece
    // directive/dil/seviye değişince değişir, ki o zaten nadir), volatile
    // her şey turnContext'e taşındı.
    let turnContext = timeContext(lastMessageAt, clientNow, tzOffsetMinutes);
    if (exHistory) {
      turnContext += `\n\n[SHARED HISTORY — reference these memories naturally in conversation]\n${exHistory}`;
    }
    turnContext += memoriesBlock(memoryRows);
    turnContext += behaviorsBlock(behaviorRows);
    // stage===2 → this turn IS the user's answer to the unanswered escalation
    // (reset happens further down, after the reply is generated) — the mood
    // rule applies to THIS reply too, not just the turns after it.
    const jealousMoodActive = convo.jealousy_stage === 2 || (convo.jealousy_mood_turns_left ?? 0) > 0;
    if (jealousMoodActive) {
      turnContext += JEALOUS_MOOD_RULE;
    }
    if (useClientHistory && localSummary && localSummary.trim() !== "") {
      turnContext += `\n\n[Önceki konuşmalarınızın özeti]\n${stripVoiceTags(localSummary)}`;
    }
    if (!useClientHistory && convo.summary && convo.summary.trim() !== "") {
      turnContext += `\n\n[Summary of your previous conversations — reference naturally, reply in the user's language regardless]\n${stripVoiceTags(convo.summary)}`;
    }
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
    if (interests.length > 0) {
      // currentActivity'nin AKSİNE tamamen susturulmuyor — kullanıcı bu
      // ilgi alanlarını KARAKTER için bilerek seçti, hiç yüzeye çıkmazlarsa
      // seçimin bir anlamı kalmıyor. Ama aynı "her turda tekrar" hatasına
      // düşmesin diye: SADECE zamanlama gerçekten uyduğunda (hafta sonu +
      // outdoor hobi, işte değilken + gaming vb.) VE çoğu turda hiç
      // bahsetmeme talimatı net.
      turnContext += `\n\n[YOUR INTERESTS — INTERNAL] You're into: ${interests.join(", ")}. ` +
        `Most turns should not reference these at all — don't list them or ` +
        `force them in. Only bring one up naturally when the moment actually ` +
        `fits (e.g. it's the weekend and you have an outdoorsy one, it's your ` +
        `free time in the evening and you have a gaming/hobby one, or the user ` +
        `asks what you're up to) — as something you're doing or planning, not ` +
        `a fact you're reciting. If none fit the current moment, ignore this ` +
        `entirely this turn.`;
    }
    // UYKU ÖZELLİĞİ KAPATILDI (kullanıcı talebi 2026-08-26) — [BEDTIME PROXIMITY]
    // notu artık turnContext'e EKLENMİYOR (kod KALDIRILMADI, aşağıda yorum
    // satırı olarak duruyor). `nearSleepTime` istemciden hâlâ gelebilir ama
    // burada kullanılmıyor.
    // if (!voiceChat && !imageReactionChat) {
    //   turnContext += nearSleepTime
    //     ? "\n\n[BEDTIME PROXIMITY] It is currently close to or within your real scheduled sleep time."
    //     : "\n\n[BEDTIME PROXIMITY] It is NOT close to your real scheduled sleep time right now.";
    // }

    // === CEVAP MODU ===
    // 2) Geçmişi al — clientHistory varsa istemciden, yoksa DB'den
    let recent: WireMessage[];
    if (useClientHistory) {
      recent = clientHistory!.slice(-KEEP_RECENT);
    } else {
      // Sondan KEEP_RECENT değil, son fold'dan (summarized_count) BU YANA
      // olan HER mesaj — append-only, bkz. FOLD_BATCH yorumu yukarıda.
      const windowStart: number = convo.summarized_count ?? 0;
      const { data: recentAsc } = await db
        .from("messages")
        .select("role, content")
        .eq("conversation_id", conversationId)
        .order("created_at", { ascending: true })
        .range(windowStart, windowStart + WINDOW_SAFETY_CAP - 1);
      recent = recentAsc ?? [];
    }
    // Geçmişteki HERHANGİ bir mesaj (fix'ten önce kaydedilmiş sesli mesaj
    // cevapları dahil) ses etiketi taşıyabilir — Grok bunu görüp taklit
    // etmesin diye burada da temizleniyor (bkz. stripVoiceTags üstteki not).
    recent = recent.map((m) => ({ ...m, content: stripVoiceTags(m.content) }));

    // Kullanıcı bir fotoğraf gönderdiyse SADECE bu turun son mesajı vision
    // content-block dizisine dönüşür — geçmiş (`recent`) ve base64 hiçbir
    // yere kaydedilmez/tekrar gönderilmez, sadece BU çağrıda xAI'ye gider.
    const finalUserContent: string | ContentBlock[] = hasUserPhoto
      ? [
          { type: "text", text: (userMessage ?? "") + turnContext },
          { type: "image_url", image_url: { url: `data:image/jpeg;base64,${userImageBase64}` } },
        ]
      : userMessage! + turnContext;

    const grokMessages: GrokMessage[] = [
      { role: "system", content: system },
      ...recent,
      { role: "user", content: finalUserContent },
    ];

    const rawReply = await callGrok(grokMessages, 350, conversationId);
    // Foto/ses işaretini metni temizlemeden ÖNCE çıkar — MEDIA_REQUEST_RULE
    // sadece düz metin turlarında enjekte edildiği için (bkz. yukarısı) burada da
    // aynı koşulla sınırlı; voice/image-reaction turlarında Grok zaten bu işareti
    // hiç görmüyor, autoMedia her zaman null kalır.
    const { text: mediaCleanedReply, media: autoMedia } =
      (!voiceChat && !imageReactionChat) ? parseMediaIntent(rawReply) : { text: rawReply, media: null };
    // Çoklu-balon bölme artık TAMAMEN istemci tarafında (bkz. collapseNewlines
    // üstteki not) — sunucu tek düz metin döner.
    const reply = collapseNewlines(mediaCleanedReply);

    // Gerçek atomik düşüm — cevap başarıyla üretildi, şimdi tahsil et.
    let tokenBalanceAfterCharge: number | undefined;
    if (!voiceChat && !imageReactionChat) {
      const charge = await chargeOrReject(uid, 1, "message");
      if (charge.ok) tokenBalanceAfterCharge = charge.balance;
    }

    // UYKU ÖZELLİĞİ KAPATILDI (kullanıcı talebi 2026-08-26) — classifySleepAgreement
    // ARTIK ÇAĞRILMIYOR (gereksiz bir LLM çağrısı daha az), wentToSleep her zaman
    // false. Kod KALDIRILMADI — geri açmak için `sleepFeatureEnabled`'ı true yapıp
    // eski koşullu ifadeyi geri getirmek yeterli: (!voiceChat && !imageReactionChat
    // && nearSleepTime) ? await classifySleepAgreement(userMessage!, reply) : false.
    const sleepFeatureEnabled = false;
    const wentToSleep = (sleepFeatureEnabled && !voiceChat && !imageReactionChat && nearSleepTime)
      ? await classifySleepAgreement(userMessage!, reply)
      : false;

    // 4) Mesajları kaydet. imageReactionChat = fotoğraf-altı metin tepkisi:
    // kullanıcı promptu ZATEN foto isteği turunda (normal send) kaydedildi,
    // burada TEKRAR user mesajı yazma (aksi halde geçmişte çift "Fotoğraf
    // gönder" görünür) — sadece asistan caption'ı sakla.
    if (voiceChat) {
      // Ses cevabı METİN olarak SAKLANMAZ — client, TTS + Storage upload'dan
      // sonra bunu `voiceMessage` (kind=voice, content=URL) olarak kalıcılaştırır.
      // Aksi halde reload'da ses yerine metin görünürdü (bkz. kullanıcı talebi).
    } else if (imageReactionChat) {
      await db.from("messages").insert([
        { conversation_id: conversationId, role: "assistant", content: reply, kind: "text" },
      ]);
    } else {
      // İKİ AYRI insert() — tek çağrıda array olarak yazılırsa Postgres'in
      // `now()` (created_at default) değeri TÜM satırlar için AYNI kalıyor
      // (bir statement içinde sabit), yani user/assistant satırları BİREBİR
      // aynı created_at'la kayıtlıyor oluyordu. `order by created_at` bu eşit
      // zamanlı satırlar için hiçbir garantili sıralama vermiyor — reload'da
      // ara sıra assistant, user'dan ÖNCE görünüyordu (bkz. kullanıcı talebi).
      // Ayrı çağrılar arasındaki gerçek (ağ/yürütme) gecikme, iki satırın
      // farklı, artan created_at almasını garantiler.
      if (hasUserPhoto && userImageBase64) {
        await persistUserPhoto(conversationId, uid, userImageBase64);
      }
      await db.from("messages").insert({ conversation_id: conversationId, role: "user", content: userMessage!, kind: "text" });
      await db.from("messages").insert({ conversation_id: conversationId, role: "assistant", content: reply, kind: "text" });
    }

    // 4b) Seviye/ilerleme SUNUCUDA hesaplanır (istemci kurcalayamaz) — HER
    // mesajda ilerleme artar, dolunca seviye atlar. Bu turun direktifi zaten
    // yukarıda eski `currentLevel` ile yapıldı; yeni değerler bir sonraki tura
    // ve cevapla istemciye yansır.
    const currentProgress: number = typeof convo.level_progress === "number" ? convo.level_progress : 0;
    const gained = applyRelationshipGain(perMessageFraction(currentLevel), currentLevel, currentProgress);
    const newLevel = gained.level;
    const newProgress = gained.progress;

    // "Sıfır yerel": durum alanları da SUNUCUDA güncellenir.
    // - ghosted_at: kullanıcı yazdı → temizle (eski noteUserSent yereli temizliyordu).
    // - manual_sleep_at: sohbet içinde uykuya anlaşıldıysa (wentToSleep) şimdi olarak set.
    // - woken_up_at: istemci uyuyan karakteri uyandırdıysa (body.wokeUp) şimdi.
    const nowIso = new Date().toISOString();
    // Jealousy state machine (bkz. JEALOUS_MOOD_RULE üstteki not, migration
    // 024_jealousy_state.sql, NotificationScheduler'daki eş taraf):
    // stage 1 (ilk kıskançlık mesajı cevapsız) → kullanıcı yazdı, sessizce 0'a
    // dön (bekleyen eskalasyon bir sonraki reschedule'da iptal olur).
    // stage 2 (eskalasyon cevapsız) → kullanıcı YANIT VERDİ: 0'a dön, kısa bir
    // "hâlâ biraz kıskanç" evresi başlat (bu tur zaten turnContext'teki
    // jealousMoodActive ile kapsandı, kalan 2 tur için sayaç kur).
    // Aksi halde: sayaç varsa bir azalt.
    const jealousyStageAtStart: number = convo.jealousy_stage ?? 0;
    let newJealousyStage = jealousyStageAtStart;
    let newJealousyMoodTurnsLeft: number = convo.jealousy_mood_turns_left ?? 0;
    if (jealousyStageAtStart === 1) {
      newJealousyStage = 0;
    } else if (jealousyStageAtStart === 2) {
      newJealousyStage = 0;
      newJealousyMoodTurnsLeft = 2;
    } else if (newJealousyMoodTurnsLeft > 0) {
      newJealousyMoodTurnsLeft -= 1;
    }

    const convoUpdate: Record<string, unknown> = {
      updated_at: nowIso,
      relationship_level: newLevel,
      level_progress: newProgress,
      ghosted_at: null,
      jealousy_stage: newJealousyStage,
      jealousy_mood_turns_left: newJealousyMoodTurnsLeft,
    };
    if (wentToSleep) convoUpdate.manual_sleep_at = nowIso;
    if (body.wokeUp === true) convoUpdate.woken_up_at = nowIso;
    await db.from("conversations")
      .update(convoUpdate)
      .eq("id", conversationId);

    const jealousyState = {
      jealousyStage: newJealousyStage,
      jealousySentAt: convo.jealousy_sent_at ?? null,
      jealousyMoodTurnsLeft: newJealousyMoodTurnsLeft,
    };

    // 5) Özetleme — sadece DB modunda (clientHistory modunda istemci geçmişi yönetiyor)
    if (useClientHistory) {
      return json({ conversationId, reply, level: newLevel, levelProgress: newProgress, wentToSleep, tokenBalance: tokenBalanceAfterCharge, autoMedia, ...jealousyState });
    }

    const { count: total } = await db
      .from("messages")
      .select("*", { count: "exact", head: true })
      .eq("conversation_id", conversationId);

    const summarizedCount: number = convo.summarized_count ?? 0;
    const agedOut = (total ?? 0) - KEEP_RECENT; // pencere KEEP_RECENT'e geri düşerse dışarda kalacak toplam
    // FOLD_BATCH kadar fazlası birikmeden fold ETME (eski koşul: `agedOut >
    // summarizedCount`, HER turda 1 mesaj kaydırıp özetleme LLM çağrısını HER
    // turda tetikliyordu). Artık sadece pencere KEEP_RECENT+FOLD_BATCH'i
    // geçince tek seferde FOLD_BATCH kadar katlanıp geri düşüyor.
    if (agedOut > summarizedCount + FOLD_BATCH) {
      // Özete eklenecek yeni eski mesajlar: [summarizedCount, agedOut)
      const { data: toFold } = await db
        .from("messages")
        .select("role, content")
        .eq("conversation_id", conversationId)
        .order("created_at", { ascending: true })
        .range(summarizedCount, agedOut - 1);

      if (toFold && toFold.length > 0) {
        const convoText = toFold
          .map((m) => `${m.role === "user" ? "User" : "You"}: ${stripVoiceTags(m.content)}`)
          .join("\n");
        const activeMemories = await fetchActiveMemories(db, conversationId);
        const existingMemoryLines = numberedMemoryLines(activeMemories);
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
              "SEPARATELY, also extract any NEW durable facts worth permanently remembering that are NOT " +
              "already covered by the existing memories list you'll be given (numbered, one per line, each " +
              "tagged with when it was first/last noted). Favor identity, personality, and life facts — who " +
              "someone IS (job, living situation, relationships, values, recurring habits, how they tend to " +
              "feel or act) — over one-off day-to-day small talk that has no lasting relevance. This isn't a " +
              "strict filter: a passing detail is still worth keeping if it's the kind of thing that should " +
              "color how the character responds days later. If there's nothing worth keeping, return an " +
              "empty array. Include BOTH sides:\n" +
              "- USER facts: name, preferences, promises, key relationship moments, recurring patterns.\n" +
              "- CHARACTER facts: things the character herself has established/committed to in this " +
              "conversation — a pet name she's adopted for the user, a boundary she's set, a backstory " +
              "detail she's improvised (job, hobby, living situation, etc.) that should stay consistent, a " +
              "promise she made. These matter just as much — a character who forgets her own established " +
              "details reads as inconsistent, not just one who forgets the user's.\n\n" +
              "RECURRENCE: if the new content restates or reinforces something an existing memory already " +
              "says (even worded differently, e.g. \"tired again today\" vs. a prior \"was tired today\"), do " +
              "NOT add it as a separate new memory. Instead put a single MERGED replacement fact in " +
              "newMemories that folds in the recurrence as an observed pattern (e.g. \"User has mentioned " +
              "feeling tired more than once (first 2026-08-28, again 2026-09-01) — seems to run low on energy " +
              "often\"), and put that existing memory's number in staleIndexes so the old single-instance " +
              "version gets replaced by the merged one.\n\n" +
              "ALSO identify any existing memories (by their number) that this new content now CONTRADICTS " +
              "— e.g. the user previously said they're a barista and now say they just started a nursing " +
              "job. Return those numbers in staleIndexes. If nothing is contradicted, return an empty array.\n\n" +
              'Respond with ONLY this JSON shape, nothing else: {"summary":"...","newMemories":["fact one",' +
              '"fact two"],"staleIndexes":[0,2]} — `summary` is the full updated USER/BOT summary text (same ' +
              "format as before), `newMemories` and `staleIndexes` are the arrays described above (can be empty).",
          },
          {
            role: "user",
            content:
              `Previous summary:\n${convo.summary || "(none)"}\n\n` +
              `Existing memories (numbered — do not repeat these, but flag contradicted ones in staleIndexes):\n${existingMemoryLines}\n\n` +
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
          const staleIndexes: number[] = Array.isArray(parsed?.staleIndexes)
            ? parsed.staleIndexes.filter((i: unknown): i is number => typeof i === "number" && Number.isInteger(i))
            : [];
          await applyMemoryExtraction(db, conversationId, activeMemories, newMemories.map((m) => m.trim()), staleIndexes);
          await pruneMemoriesIfOverCap(db, conversationId, callGrok);
        } catch (e) {
          // Özetleme başarısız olsa bile sohbet bozulmaz; sadece logla.
          console.error("ozetleme hatasi:", String(e));
        }
      }
    }

    return json({ conversationId, reply, level: newLevel, levelProgress: newProgress, wentToSleep, tokenBalance: tokenBalanceAfterCharge, autoMedia, ...jealousyState });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
