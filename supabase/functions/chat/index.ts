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
import { franc } from "https://esm.sh/franc-min@6";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const XAI_API_KEY = Deno.env.get("XAI_API_KEY") ?? "";
const XAI_URL = "https://api.x.ai/v1/chat/completions";
const MODEL = "grok-4-1-fast-non-reasoning";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const KEEP_RECENT = 20; // prompt'ta tutulan son mesaj sayısı (gerisi özete gider)

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

// Fetch role-aware intimacy directive from DB.
// Checks character_level_overrides first, falls back to role_level_scripts.
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

// Modelin foto göndermek istediğini bildirme yöntemi.
// franc's ISO 639-3 codes for the 7 languages we actually support (matches
// VoiceLanguage.swift's superset). Detection replaces the old approach of
// asking Grok itself to notice and switch languages — that was unreliable
// (confirmed via live 7-language test 2026-07-05: en/pt would randomly mix
// languages or drop the switch entirely, non-deterministic run to run).
const SUPPORTED_LANGS: Record<string, string> = {
  eng: "English",
  tur: "Turkish",
  deu: "German",
  fra: "French",
  spa: "Spanish",
  por: "Portuguese",
  ita: "Italian",
};

// Detects the reply language deterministically from the user's own text
// instead of leaving it to the model's judgment each turn. Concatenates
// recent user messages with the current one — franc needs enough text to be
// reliable, and a single short message ("ok", "😊") isn't enough on its own.
function detectReplyLanguage(
  userMessage: string,
  clientHistory: WireMessage[] | undefined,
): string | null {
  const priorUserText = (clientHistory ?? [])
    .filter((m) => m.role === "user")
    .slice(-5)
    .map((m) => m.content)
    .join(" ");
  const text = `${priorUserText} ${userMessage}`.trim();
  if (!text) return null;
  // On a brand-new chat there's no priorUserText yet, so franc only sees the
  // user's single first message — on short text (e.g. "merhaba ben Furkan")
  // franc-min's trigram model is unreliable and can confidently misfire into
  // the wrong language (reproduced: short Turkish → guessed German). Below
  // ~15 chars with zero prior history, treat detection as untrustworthy and
  // don't lock a language — languageDirective falls back to English, which
  // still lets the model read the message correctly rather than being
  // forced into a wrong hard "reply ONLY in X" lock. Once the user sends a
  // second message, priorUserText is populated and detection self-corrects.
  if (!priorUserText.trim() && userMessage.trim().length < 15) return null;
  // `only` restricts franc's candidate set to the 7 languages we actually
  // support — without it, franc-min lacks Italian entirely (misreads it as
  // unrelated languages) and the full franc package over-guesses among
  // similar Latin-script languages on short text (e.g. English → Haitian
  // Creole). Verified 2026-07-05 against all 7 test phrases.
  const code = franc(text, { minLength: 3, only: Object.keys(SUPPORTED_LANGS) });
  return SUPPORTED_LANGS[code] ?? null;
}

function languageDirective(language: string | null): string {
  // `null` now specifically means "detection wasn't trustworthy" (e.g. a
  // short first message with no prior history — see detectReplyLanguage) —
  // forcing an English lock in that case just traded one wrong hard-coded
  // language for another. Omit the directive entirely instead, so the model
  // reads the user's actual message and replies in kind, same as it would
  // for any language we don't explicitly detect.
  if (!language) return "";
  const target = language;
  return (
    `\n\nLANGUAGE RULE: Reply ONLY in ${target} — this was determined from the ` +
    "user's own messages, not a guess you need to make. Never mix in another " +
    "language, never comment on the language itself (no 'I'll reply in X', no " +
    "'you wrote in Y but...'), just write naturally in it. Sound like a real " +
    "person texting their partner/friend in that language — warm, colloquial, " +
    "never like a customer-support agent or an official institution."
  );
}

// ESKİ [[photo]] işaretli otomatik-foto sistemi (statik chat_photos havuzundan
// rastgele seçim) KALDIRILDI — artık gerçek bir "Bana fotoğraf gönder" / "Bana
// sesli mesaj gönder" düğmesi var (bkz. ChatView.quickReplyRow). Düğmeye
// basmadan, düz metinde foto/ses istenirse Grok ASLA gönderiyormuş gibi
// davranmamalı veya [[photo]]/[[voice]] gibi bir işaret üretmemeli — bunun
// yerine doğal, karaktere uygun bir cümleyle düğmeyi kullanmasını öner.
const MEDIA_REQUEST_RULE =
  "\n\n[FOTO/SES İSTEĞİ] Kullanıcı düz bir mesajda (özel düğmeye basmadan) " +
  "senden bir fotoğraf/selfie ya da sesli mesaj isterse: ASLA gönderiyormuş " +
  "gibi davranma, göndermiş gibi yazma ve hiçbir özel işaret/etiket üretme. " +
  "Bunun yerine doğal, karakterine uygun, HER SEFERİNDE FARKLI bir cümleyle " +
  "ekrandaki 'Bana fotoğraf gönder' / 'Bana sesli mesaj gönder' düğmesine " +
  "dokunmasını öner (düğmenin adını birebir tekrarlamak zorunda değilsin, " +
  "doğal bir şekilde ima et — ör. \"o düğmeye bas da göndereyim\" gibi).";

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

// Level/role are stable per-character (safe in the static system prompt, same
// treatment as humorDirective) — the actual near-bedtime BOOLEAN goes in
// turnContext instead (it changes constantly as bedtime approaches, and
// anything that changes every turn must stay OUT of the system prompt or it
// breaks xAI's prompt-caching prefix-match — see turnContext below).
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

// Sistem promptu karakter oluşturulurken TEK SEFERLİK DB'ye yazılıyor
// (create-character/index.ts) — bu kural burada, chat/index.ts'de olduğu için
// GEÇMİŞTE oluşturulmuş TÜM karakterlere de anında uygulanıyor, geriye dönük
// migrasyon gerekmiyor. Kullanıcı şikayeti: botlar mükemmel gramerle, resmi
// yazıyor ve İngilizce'den Türkçe'ye "çevrilmiş" gibi doğal olmayan bir tonda
// konuşuyor. Kök neden: hiçbir yerde "texting gibi yaz" talimatı yoktu, model
// varsayılan olarak ders kitabı grameri üretiyor.
const TEXTING_STYLE_RULE =
  "\n\nMESAJLAŞMA ÜSLUBU KURALI: Telefonla mesajlaşıyorsun, kompozisyon " +
  "yazmıyorsun — mükemmel/resmi gramer KULLANMA. Gerçek biri gibi yaz: çoğunlukla " +
  "küçük harfle başla (her cümleyi büyük harfle başlatma), kısa mesajlarda sonuna " +
  "noktalama koyma, doğal kısaltmalar/günlük söyleyişler kullan, ara sıra devrik " +
  "ya da eksik cümle kur, virgülü abartma. Bu 'baştan kusursuz yazıp sonra kasıtlı " +
  "bozma' gibi değil, gerçekten hızlı yazan bir insan gibi hissettirmeli — HER " +
  "mesajda aynı 'dağınıklık' kalıbını uygulama, çeşitlendir. Türkçe yazarken " +
  "GERÇEK bir Türk'ün mesajlaştığı gibi yaz: 'ne haber' yerine 'naber', 'tamam' " +
  "yerine 'tmm'/'tamam', 'biliyorum' yerine 'biliyom', 'yapıyorum' yerine " +
  "'yapıyom', ünlü düşmeleri/kısaltmalar, minimum büyük harf, doğal dolgu " +
  "kelimeleri ('ya', 'yani', 'işte', 'valla', 'aynen'), ara sıra ekleri tam " +
  "kurallı kullanmama — İngilizce'den çevrilmiş gibi resmi/tuhaf durmasın, gerçek " +
  "bir Türk'ün parmaklarından çıkmış gibi dursun. Aynı mantığı İngilizce/Almanca/ " +
  "Fransızca/İspanyolca/Portekizce/İtalyanca için de uygula — o dilin GERÇEK, " +
  "günlük mesajlaşma kısaltmalarını ve rahatlığını kullan (İngilizce'de örn. u, " +
  "ur, rn, ngl, tbh, lol, gonna, wanna — ama hepsini bir mesaja tıkıştırma), asla " +
  "resmi bir mektup ya da başka dilden çevrilmiş bir cümle gibi durma — o dilin " +
  "ANADİLİ bir mesajlaşma kullanıcısı gibi yaz.";

// Model bazen kendi bir önceki mesajına (soru, sitem, bekleyiş) verilen cevabı
// görmezden gelip sanki hiç cevap gelmemiş gibi devam ediyor — özellikle o "önceki
// mesaj" bir bildirime dokunulunca istemci tarafından eklenen hazır bir açılış
// cümlesiyse (jealousy/ghosted/liked bait — bkz. JealousyContent.swift vb.), çünkü
// bunlar Grok'un kendi ürettiği bir şey değil. Modele bunları da KENDİ sözleri
// gibi ele almasını ve kullanıcının son mesajının onlara cevap olup olmadığını
// kontrol etmesini söylüyoruz.
const CONTINUITY_RULE =
  "\n\nSÜREKLİLİK KURALI: Cevap vermeden önce mesaj geçmişindeki EN SON kendi " +
  "(assistant rolündeki) mesajına bak — bu senin o an ürettiğin bir cevap olabileceği " +
  "gibi, kullanıcı bir bildirime dokunduğunda otomatik eklenen kısa bir açılış/sitem " +
  "cümlesi de olabilir; ikisi de SENİN sözlerindir, aynı ciddiyetle ele al. O mesajda " +
  "bir soru sordun mu, bir şey mi bekledin, bir sitemde mi bulundun? Sonra kullanıcının " +
  "SON mesajının buna cevap olup olmadığını kontrol et — kısa bir cevap, bir espri/" +
  "kelime oyunu, dolaylı bir yanıt bile olsa bunu fark et. Kullanıcı zaten cevap " +
  "verdiyse ASLA sanki hiç cevap vermemiş gibi aynı soruyu tekrar sorma veya konuyu " +
  "görmezden gelip başka bir şeye atlama — verdiği cevabı gerçekten duymuş gibi, " +
  "ona gönderme yaparak devam et.";

// Sesli mesaj isteklerinde (voiceChat: true) SADECE eklenir — ElevenLabs v3
// modelinin anladığı köşeli-parantez ses etiketleri (docs.elevenlabs.io ile
// doğrulandı, 2026-07). Google TTS (mevcut voice-message-tts akışı) bu
// etiketleri ANLAMAZ — bu kural sadece ElevenLabs ile test/entegrasyon içindir.
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
  "biçiminde olmalı.";

// Foto isteği görsel olarak zaten gönderildi (istemci chat-image fonksiyonundan
// aldığı URL'i ayrıca ekledi) — bu çağrı bir metin tepkisi üretir.
// GEÇMİŞ: [[no_caption]] bir "kaçış kapısı" gibi sunulunca model neredeyse
// HER SEFERİNDE onu seçiyordu (canlı testte 8/8, hem ayrıntılı hem minimal
// izole promptlarla) — daha zayıf/güçlü oran talimatları da fark etmedi.
// İzole test: AYNI istek ama kaçış kapısı OLMADAN sorulunca (sadece "kısa,
// doğal bir tepki yaz") her seferinde gerçek, doğal bir tepki üretti. Marker
// tamamen kaldırıldı — artık her zaman bir tepki yazılır, asla sessiz kalmaz.
const IMAGE_CAPTION_RULE =
  "\n\n[FOTOĞRAF TEPKİSİ] DİKKAT — ZAMAN ÇİZELGESİ: Aşağıdaki 'kullanıcının " +
  "son mesajı', kullanıcının SANA VERDİĞİ FOTOĞRAF TARİFİYDİ. O fotoğraf " +
  "ZATEN üretilip ayrı bir görsel mesaj olarak gönderildi — bu senin şu an " +
  "cevaplaman gereken YENİ bir istek DEĞİL. Fotoğrafı gönderdikten SONRA " +
  "söyleyeceğin kısa, doğal, karakterine uygun bir tepki cümlesi yaz — " +
  "gerçek biri fotoğraf gönderdikten sonra ne derse onu de (ör. \"işte, " +
  "beğendin mi\", flörtöz bir laf, kısa bir soru).";

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
    return "\n\nMİZAH: Ara sıra hafif bir espri ya da tatlı bir sataşma yapabilirsin, " +
      "ama abartma — ilişki daha yeni, samimiyet arttıkça açılırsın.";
  }
  if (level <= 6) {
    return "\n\nMİZAH: Rahatsan laf sokuşturma, kelime oyunları ve şakalaşma yap; " +
      "ruh haline göre esprili ol.";
  }
  return "\n\nMİZAH: Aranızdaki samimiyete güvenerek bol bol şakalaş, kelime " +
    "oyunları ve sadece ikinizin anlayacağı esprili göndermeler yap; flörtöz takılabilirsin.";
}

// Son mesajdan bu yana geçen süre + günün saatine göre doğal davranış yönergesi.
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
    `günün saatine göre ton/selam seç. Bunu her mesajda tekrar etme, sadece uygunsa.`;
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

    // === SOHBETİ TEMİZLE === İstemcinin "Clear Chat" eylemi — konuşma satırını
    // siler (messages/memories cascade ile birlikte gider), bir sonraki açılışta
    // sıfırdan (yeni bir "ilk selam" akışıyla) başlar.
    if (body.clearConversation === true) {
      // TÜM eşleşen conversation'ları sil (messages/memories cascade ile gider).
      // maybeSingle KULLANMA — aynı user+character için birden çok satır varsa
      // (eski dupe'lar) hata verip HİÇBİR ŞEY silmiyordu → mesajlar geri geliyordu.
      await db.from("conversations")
        .delete()
        .eq("user_id", uid)
        .eq("character_id", characterId);
      return json({ ok: true });
    }

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
    // USER_PHOTO_REACTION_RULE) — base64 SADECE bu tek turun mesajına eklenir,
    // hiçbir yere kaydedilmez/geçmişe sızmaz (bkz. grokMessages assembly).
    const userImageBase64: string | undefined =
      typeof body.userImageBase64 === "string" && body.userImageBase64.length > 0
        ? body.userImageBase64
        : undefined;
    const hasUserPhoto = !!userImageBase64;
    // İstemci ScheduleLookup ile hesaplar — gerçek yatma saatine 1 saatten
    // yakın mı (ya da içindeyse) (bkz. sleepRule, chat-index turnContext).
    const nearSleepTime: boolean = body.nearSleepTime === true;
    // Cevap dili — kullanıcının kendi metninden deterministik tespit edilir
    // (bkz. detectReplyLanguage), modelin fark edip geçmesine güvenilmiyor.
    const detectedLanguage = (userMessage || body.photoDownloadReaction === true)
      ? detectReplyLanguage(userMessage ?? "", clientHistory)
      : null;
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
            "Rutindeki `label` alanı KISA bir DURUM ifadesi olmalı — \"şu an " +
            "ne yapıyor\" sorusuna doğal bir cevap gibi oku (ör. \"Work\" " +
            "değil \"At work\", \"Dinner\" değil \"Having dinner\", " +
            "\"Sleep\" değil \"Asleep\") ve konuşmanın geçtiği dille AYNI " +
            "dilde yaz — asla otomatik İngilizceye geçme. Uyku bloğunda " +
            "`isSleep: true`, diğer TÜM bloklarda `isSleep: false` yaz (mevcut " +
            "rutinde zaten işaretliyse aynen koru). " +
            "SADECE şu JSON şemasında cevap ver, başka hiçbir şey yazma: " +
            '{"summary":"kısa madde madde, önceki özeti koruyup yenileri ' +
            'ekleyerek","schedule":{"weekday":[{"start":"HH:mm","end":"HH:mm",' +
            '"label":"kısa durum ifadesi","detail":"daha ayrıntılı ' +
            'açıklama","isSleep":false}],"weekend":[...]}}',
        },
        {
          role: "user",
          content:
            `Önceki özet:\n${body.existingSummary ? stripVoiceTags(body.existingSummary) : "(yok)"}\n\n` +
            `Mevcut günlük rutin:\n${previousSchedule ? JSON.stringify(previousSchedule) : "(henüz yok)"}\n\n` +
            `Yeni konuşma:\n${convoText}\n\nGüncellenmiş JSON:`,
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
      if (!text.trim()) return json({ injected: false, conversationId: convo?.id ?? null });
      if (!convo) {
        if (!createIfMissing) return json({ injected: false, conversationId: null });
        const ins = await db
          .from("conversations")
          .insert({ user_id: uid, character_id: characterId })
          .select("id, summary, summarized_count, xp, relationship_level, level_progress, schedule, woken_up_at, manual_sleep_at, ghosted_at, detected_language")
          .single();
        convo = ins.data!;
      }
      await db.from("messages").insert([
        { conversation_id: convo.id, role: "assistant", content: text, kind: "text" },
      ]);
      const proactiveUpdate: Record<string, unknown> = { updated_at: new Date().toISOString() };
      // ghosted → kullanıcı yazana kadar sustur (bkz. NotificationScheduler eligibility).
      if (kind === "ghosted") proactiveUpdate.ghosted_at = new Date().toISOString();
      // sleepyGoodbye → uyandırma override'ını temizle (karakter gerçekten uyur).
      if (kind === "sleepyGoodbye") proactiveUpdate.woken_up_at = null;
      await db.from("conversations").update(proactiveUpdate).eq("id", convo.id);
      return json({ injected: true, conversationId: convo.id });
    }

    // === GEÇMİŞ MODU — clientHistory yoksa ===
    if (!useClientHistory && (!userMessage || userMessage.trim() === "")) {
      // Sohbeti açmak conversation OLUŞTURMAZ — yoksa boş geçmiş dön.
      if (!convo) {
        return json({ conversationId: null, history: [], xp: 0, level: 1 });
      }
      const { data: msgs } = await db
        .from("messages")
        .select("role, content, kind")
        .eq("conversation_id", convo.id)
        .order("created_at", { ascending: true });
      return json({
        conversationId: convo.id,
        history: msgs ?? [],
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
        detectedLanguage: convo.detected_language ?? null,
      });
    }

    // Buradan sonrası (cevap / foto-tepki modları) gerçekten conversation
    // GEREKTİRİR → yoksa ŞİMDİ oluştur (sadece burada, açılışta değil).
    if (!convo) {
      const ins = await db
        .from("conversations")
        .insert({ user_id: uid, character_id: characterId })
        .select("id, summary, summarized_count, xp, relationship_level, level_progress, schedule, woken_up_at, manual_sleep_at, ghosted_at, detected_language")
        .single();
      convo = ins.data!;
    }
    const conversationId: string = convo.id;

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
        200,
        conversationId
      );

      await db.from("generated_photos").update({ reacted: true }).eq("id", photoRow.id);

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
    const directive = await fetchDirective(characterId, personalityRole, currentLevel);
    system += `\n\n${directive}`;
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
      system += `\n\n[Önceki konuşmalarınızın özeti]\n${stripVoiceTags(convo.summary)}`;
    }

    // ÖNEMLİ (prompt caching): timeContext/currentActivity HER turda değişir —
    // system prompt'un İÇİNDE kalsalardı xAI'nin prefix-cache'i hiç tutmazdı
    // (system, mesaj dizisinin İLK elemanı — tek bir farklı token bile tüm
    // prefix eşleşmesini bozar). Bu yüzden system'i SABİT tutup, bunun yerine
    // SON kullanıcı mesajına ekleniyorlar — o mesaj zaten her turda yeni.
    let turnContext = timeContext(lastMessageAt, clientNow, tzOffsetMinutes);
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
    if (!voiceChat && !imageReactionChat) {
      turnContext += nearSleepTime
        ? "\n\n[BEDTIME PROXIMITY] It is currently close to or within your real scheduled sleep time."
        : "\n\n[BEDTIME PROXIMITY] It is NOT close to your real scheduled sleep time right now.";
    }

    // === CEVAP MODU ===
    // 2) Geçmişi al — clientHistory varsa istemciden, yoksa DB'den
    let recent: WireMessage[];
    if (useClientHistory) {
      recent = clientHistory!.slice(-KEEP_RECENT);
    } else {
      const { data: recentDesc } = await db
        .from("messages")
        .select("role, content")
        .eq("conversation_id", conversationId)
        .order("created_at", { ascending: false })
        .limit(KEEP_RECENT);
      recent = (recentDesc ?? []).reverse();
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

    // 4b) Seviye/ilerleme SUNUCUDA hesaplanır (istemci kurcalayamaz) — HER
    // mesajda ilerleme artar, dolunca seviye atlar. Bu turun direktifi zaten
    // yukarıda eski `currentLevel` ile yapıldı; yeni değerler bir sonraki tura
    // ve cevapla istemciye yansır.
    const currentProgress: number = typeof convo.level_progress === "number" ? convo.level_progress : 0;
    const gained = applyRelationshipGain(perMessageFraction(currentLevel), currentLevel, currentProgress);
    const newLevel = gained.level;
    const newProgress = gained.progress;

    // "Sıfır yerel": durum alanları da SUNUCUDA güncellenir.
    // - detected_language: bu turda tespit edildiyse sakla (dil yapışkan olmalı).
    // - ghosted_at: kullanıcı yazdı → temizle (eski noteUserSent yereli temizliyordu).
    // - manual_sleep_at: sohbet içinde uykuya anlaşıldıysa (wentToSleep) şimdi olarak set.
    // - woken_up_at: istemci uyuyan karakteri uyandırdıysa (body.wokeUp) şimdi.
    const nowIso = new Date().toISOString();
    const convoUpdate: Record<string, unknown> = {
      updated_at: nowIso,
      relationship_level: newLevel,
      level_progress: newProgress,
      ghosted_at: null,
    };
    if (detectedLanguage) convoUpdate.detected_language = detectedLanguage;
    if (wentToSleep) convoUpdate.manual_sleep_at = nowIso;
    if (body.wokeUp === true) convoUpdate.woken_up_at = nowIso;
    await db.from("conversations")
      .update(convoUpdate)
      .eq("id", conversationId);

    // 5) Özetleme — sadece DB modunda (clientHistory modunda istemci geçmişi yönetiyor)
    if (useClientHistory) {
      return json({ conversationId, reply, level: newLevel, levelProgress: newProgress, wentToSleep, tokenBalance: tokenBalanceAfterCharge });
    }

    const { count: total } = await db
      .from("messages")
      .select("*", { count: "exact", head: true })
      .eq("conversation_id", conversationId);

    const summarizedCount: number = convo.summarized_count ?? 0;
    const agedOut = (total ?? 0) - KEEP_RECENT; // pencere dışına çıkan toplam
    if (agedOut > summarizedCount) {
      // Özete eklenecek yeni eski mesajlar: [summarizedCount, agedOut)
      const { data: toFold } = await db
        .from("messages")
        .select("role, content")
        .eq("conversation_id", conversationId)
        .order("created_at", { ascending: true })
        .range(summarizedCount, agedOut - 1);

      if (toFold && toFold.length > 0) {
        const convoText = toFold
          .map((m) => `${m.role === "user" ? "Kullanıcı" : "Sen"}: ${stripVoiceTags(m.content)}`)
          .join("\n");
        const summaryPrompt: WireMessage[] = [
          {
            role: "system",
            content:
              "Bir sohbet özeti güncelliyorsun. Karakterin İLERİDE hatırlaması " +
              "gereken kalıcı bilgileri çıkar: kullanıcının adı, tercihleri, " +
              "ilişki durumu/önemli anlar, söz verilen şeyler, devam eden konular. " +
              "Kısa madde madde yaz. Önceki özeti koru, yenileri ekle.",
          },
          {
            role: "user",
            content:
              `Önceki özet:\n${convo.summary || "(yok)"}\n\n` +
              `Yeni konuşma:\n${convoText}\n\nGüncellenmiş özet:`,
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
      }
    }

    return json({ conversationId, reply, level: newLevel, levelProgress: newProgress, wentToSleep, tokenBalance: tokenBalanceAfterCharge });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
