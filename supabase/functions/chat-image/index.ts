// supabase/functions/chat-image/index.ts
//
// Kullanicinin sohbette yazdigi tarif metninden xAI ile bir fotoğraf üretir.
// İKİ AŞAMA:
//   1) Grok (metin modeli) kullanıcının isteğini + karakterin görünümünü bir
//      "fotoğraf yönetmeni" talimatıyla değerlendirip TEK bir ayrıntılı
//      görsel-üretim promptu yazar (kamera/telefon modeli, açı, ışık, ISO/
//      grain, flaş, renk grading, cilt dokusu — bkz. composeImagePrompt).
//   2) O prompt, Grok Imagine'e gönderilir — karakterin mevcut profil fotoğrafı
//      varsa /v1/images/edits (image-to-image, temel/baseline görsel olarak)
//      kullanılır, yoksa (ya da edits başarısız olursa) düz /v1/images/generations'a
//      düşer. Her ikisinde de aspect_ratio=9:16, resolution=2k sabit.
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
const XAI_CHAT_URL = "https://api.x.ai/v1/chat/completions";
const TEXT_MODEL = "grok-4-1-fast-non-reasoning";

const XAI_IMAGE_GENERATIONS_URL = "https://api.x.ai/v1/images/generations";
const XAI_IMAGE_EDITS_URL = "https://api.x.ai/v1/images/edits";
const IMAGE_MODEL = "grok-imagine-image";
const IMAGE_RESOLUTION = "2k";
const IMAGE_ASPECT_RATIO = "9:16"; // docs.x.ai ile doğrulandı (2026-07): desteklenen değerlerden biri

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

async function chargeOrReject(uid: string, amount: number, reason: string): Promise<{ ok: true; balance: number } | { ok: false }> {
  const { data: charged } = await db.rpc("charge_tokens", { p_user_id: uid, p_amount: amount, p_reason: reason });
  if (!charged) return { ok: false };
  const { data: row } = await db.from("token_balances").select("balance").eq("user_id", uid).single();
  return { ok: true, balance: row?.balance ?? 0 };
}

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
  body_type?: string;
}

// Görüntü içinde ASLA yazı/metin/logo olmasın — hem talimat metninde hem de
// modelin unutması ihtimaline karşı final prompt'un sonuna sabit olarak eklenir.
const NO_TEXT_RULE =
  "The image must contain absolutely no text, letters, numbers, captions, " +
  "subtitles, watermarks, logos, or writing of any kind anywhere in the frame.";

// Tight framing (ceiling lights/door frames/furniture awkwardly clipped at the
// very top or side edge, near-zero headroom above the head) reads as "cropped"
// even when the display container's aspect ratio is mathematically correct —
// this got reported as a crop bug when it was actually a composition problem.
const FRAMING_RULE =
  "The output canvas is a TALL VERTICAL 9:16 frame (like a phone photo/story). " +
  "Compose for that shape: leave natural headroom above the subject's head, " +
  "and choose a pose/crop (e.g. waist-up, three-quarter, or full-body) that " +
  "fits the vertical frame comfortably. Never awkwardly clip background " +
  "objects (ceiling lights, door frames, furniture, signs) right at the edge " +
  "of the frame — either include them fully or leave them out of the shot.";

function appearanceContext(opts: {
  name: string;
  profession: string | null;
  tagline: string | null;
  builderSelections: BuilderSelections | null;
}): string {
  const bs = opts.builderSelections;
  const bodyType = bs?.body_type ? `, ${bs.body_type.toLowerCase()} body type` : "";
  const base = (bs && (bs.hairstyle || bs.hair_color || bs.eye_shape || bs.eye_color))
    ? `${opts.name}, a person with ${(bs.hairstyle ?? "").toLowerCase()} ` +
      `${(bs.hair_color ?? "").toLowerCase()} hair, ${(bs.eye_shape ?? "").toLowerCase()} ` +
      `${(bs.eye_color ?? "").toLowerCase()} eyes, ${(bs.nose_shape ?? "").toLowerCase()} nose, ` +
      `${(bs.skin_tone ?? "").toLowerCase()} skin tone${bodyType}`
    // Katalog karakteri — kayıtlı görünüm alanı yok, en iyi ihtimalle isim/meslek.
    : `${opts.name}${opts.profession ? `, a ${opts.profession.toLowerCase()}` : ""}`;
  // Bio/tagline genelde meslek/yaşam detayı taşır (ör. "araştırma laboratuvarında
  // çalışan bir bilim insanı") — LOCATION alanının somut bir yer üretmesi için
  // önemli bir sinyal, önceden hiç kullanılmıyordu.
  return opts.tagline ? `${base}. Bio: ${opts.tagline}` : base;
}

// Kullanıcının sohbette daha önce kurduğu gerçekler (ör. "laboratuvarda
// çalışıyorum") sadece cihaz-yerel geçmişte var olabilir — istemci bunu
// `history`/`summary` olarak gönderirse burada kullanılır. YOKSA composer bu
// tür detayları TAHMİN ETMEK ZORUNDA kalır (bkz. LOCATION alan talimatı).
function stripVoiceTags(text: string): string {
  return text.replace(/\[[^\]]*\]/g, "").replace(/[ \t]{2,}/g, " ").trim();
}

function conversationContext(history: { role: string; content: string }[], summary: string | null): string {
  const parts: string[] = [];
  // Ses etiketleri ([laughs] vb.) bu prompta sızarsa, yönetmen bunları gerçek
  // sahne detayı sanıp SUBJECT/POSE alanlarına yanlışlıkla sızdırabilir —
  // aynı temizleme chat/index.ts'de de var (bkz. oradaki stripVoiceTags notu).
  if (summary && summary.trim()) parts.push(stripVoiceTags(summary));
  if (history.length > 0) {
    parts.push(history.slice(-12).map((m) => `${m.role === "user" ? "User" : "Character"}: ${stripVoiceTags(m.content)}`).join("\n"));
  }
  if (parts.length === 0) return "";
  return (
    "\n\nCONTEXT FROM THIS CONVERSATION (use this for any established facts " +
    "about the character's life — job, workplace, ongoing storyline, etc. — " +
    "but the user's request below still takes priority for what to actually " +
    "depict):\n" + parts.join("\n\n")
  );
}

// İstemcinin ScheduleLookup ile hesapladığı "şu an ne yapıyor" bloğu (bkz.
// chat/index.ts GÜNLÜK RUTİN notu) — bu olmadan foto her zaman genel
// meslek/kategori varsayımına düşüyordu (ör. "laboratuvarda" fotoğraf, kız
// aslında o an kanepede kitap okuyorken/evdeyken bile) — bkz. kullanıcı
// raporu: metin cevabı doğru aktiviteyi yansıttı ama foto yansıtmadı.
function currentActivityContext(currentActivity: string | null): string {
  if (!currentActivity || !currentActivity.trim()) return "";
  return (
    "\n\nCHARACTER'S CURRENT REAL-TIME SITUATION — reflect this in LOCATION/" +
    "POSE/OUTFIT unless the user's request explicitly specifies otherwise " +
    "(this is what the character is ACTUALLY doing right now, takes " +
    "priority over generic profession-based assumptions): " + currentActivity.trim()
  );
}

// Kalibrasyon örneği — kullanıcının verdiği örnekle birebir aynı, sadece
// FORMATI/ayrıntı seviyesini göstermek için modele verilir (içeriği değil).
const FIELD_FORMAT_EXAMPLE =
  "CAMERA DETAILS: Shot on disposable camera, direct flash, on-camera flash " +
  "harsh lighting, visible grain, slight red-eye effect, overexposed highlights\n" +
  "LIGHTING: Flash illuminating subject sharply against a darker room\n" +
  "SUBJECT: 22 year old woman, long wavy dark hair, minimal makeup, relaxed " +
  "expression\n" +
  "OUTFIT: Oversized band t-shirt, shorts, barefoot\n" +
  "POSE: Sitting cross-legged on bedroom floor, looking directly at camera, " +
  "leaning slightly forward\n" +
  "LOCATION: Bedroom at night, messy bed in background, clothes on chair";

// ÖNEMLİ: composeImagePrompt'taki Grok çağrısı SALT METİN — baseline referans
// fotoğrafı GÖRMÜYOR (vision değil, chat/completions metin çağrısı). Bu yüzden
// stil kararı ("gerçekçi mi, anime mi kalsın") ASLA "resme bak" diye modele
// bırakılmaz — DB'deki gerçek `category` alanına göre DETERMİNİSTİK seçilir.
// Baseline sadece YÜZ/KARAKTER TUTARLILIĞI için ek bir not olarak eklenir —
// asıl görsel-görsel eşleşmeyi zaten /v1/images/edits'e giden GERÇEK referans
// görsel (bkz. fetchGeneratedImageBytes) sağlıyor, metin bunu SÖYLEMEZ, sadece
// modelin o tutarlılığı bozacak çelişkili detaylar yazmamasını sağlar.
function baselineConsistencyNote(): string {
  return (
    "\nA baseline reference image of this exact character is separately " +
    "attached to the image generator (you cannot see it, but it will be used " +
    "for face/hair/character-design consistency). THE FACE IS NON-NEGOTIABLE " +
    "— it must be recognizably the SAME PERSON as the reference: same face " +
    "shape, same bone structure, same freckles/moles/distinguishing marks, " +
    "same exact face. Never describe a different face, hairstyle, or " +
    "character design than what's implied above — only the expression, " +
    "outfit, pose, and location may change per the user's request.\n"
  );
}

function realisticFieldGuidance(): string {
  return (
    "CAMERA DETAILS: default to \"Shot on iPhone 17 Pro Max\" unless the mood " +
    "calls for something else (e.g. a disposable camera with direct on-camera " +
    "flash, harsh lighting, visible grain, slight red-eye, overexposed " +
    "highlights, for a raw candid night photo). Always state realistic sensor " +
    "characteristics: visible grain/noise appropriate to the lighting, and " +
    "whether an on-camera flash is used.\n" +
    "LIGHTING: the specific light source and quality (soft window daylight, " +
    "golden hour, harsh direct flash, warm indoor lamp, overcast, candlelight, " +
    "etc.) matching the scene, with natural true-to-life color — never " +
    "oversaturated or neon.\n" +
    "SUBJECT: the character's appearance (given below), plus natural skin " +
    "texture with visible pores and subtle imperfections — NEVER \"plastic,\" " +
    "\"airbrushed,\" \"waxy,\" \"over-smoothed,\" or \"AI-generated\" looking " +
    "skin. EXPRESSION MUST MATCH THE MOOD OF THIS SPECIFIC PHOTO, not the " +
    "character's default/profile-picture smile — a baseline reference photo " +
    "showing her smiling does NOT mean every photo should smile. Choose " +
    "whatever expression a real person would actually have for this exact " +
    "moment/pose/outfit/request (e.g. a smoldering, half-lidded, or serious/" +
    "sultry look for something intimate or a thirst-trap-style photo; a " +
    "genuine laugh for something silly; a soft neutral look for something " +
    "candid) — reason it out per the specific photo, never default to " +
    "smiling out of habit.\n" +
    "OUTFIT: exactly what the character is wearing, specific enough to " +
    "visualize (garment type, fit, color) — infer something fitting if the " +
    "user didn't specify.\n" +
    "POSE: exactly how the character is positioned — where their arms and legs " +
    "are, their posture, what they're looking at.\n" +
    "LOCATION: the specific background and setting — be concrete about what's " +
    "visible around the character. If the user's request is generic (e.g. " +
    "\"her workplace\", \"where she works\"), infer the SPECIFIC real-world " +
    "setting implied by the character's actual profession/bio/conversation " +
    "context below (a scientist's workplace is a lab, not a generic office; a " +
    "chef's workplace is a kitchen; a musician's workplace is a studio or " +
    "stage) — never default to a generic corporate office unless that's " +
    "genuinely what fits.\n"
  );
}

// "Fictional" folds anime/fantasy/sci-fi into one non-realistic bucket (see
// ExploreCategory.swift/CreateCharacterView) — no single fixed style cue fits
// all of those, so Grok picks whichever illustrated style actually suits the
// character and the user's request instead of being locked to one look.
function styledFieldGuidance(): string {
  return (
    "CAMERA DETAILS: this is a STYLIZED/ILLUSTRATED (non-photorealistic) " +
    "character — choose whichever illustrated art style best fits the " +
    "character and the user's request (e.g. anime/cel-shaded illustration, " +
    "fantasy digital painting, sci-fi digital art, or another fitting " +
    "illustrated style), and name that exact style and rendering technique " +
    "explicitly instead of a camera/phone.\n" +
    "LIGHTING: the specific light source, quality, and overall color palette " +
    "matching the scene and art style.\n" +
    "SUBJECT: the character's appearance (given below). EXPRESSION MUST MATCH " +
    "THE MOOD OF THIS SPECIFIC PHOTO, not the character's default/profile-" +
    "picture smile — a baseline reference showing her smiling does NOT mean " +
    "every photo should smile. Choose whatever expression actually fits this " +
    "exact moment/pose/outfit/request (e.g. smoldering/half-lidded/serious " +
    "for something intimate or a thirst-trap-style photo, a genuine laugh for " +
    "something silly, soft/neutral for something candid) — never default to " +
    "smiling out of habit.\n" +
    "OUTFIT: exactly what the character is wearing, specific enough to " +
    "visualize — infer something fitting if the user didn't specify.\n" +
    "POSE: exactly how the character is positioned — where their arms and legs " +
    "are, their posture, what they're looking at.\n" +
    "LOCATION: the specific background and setting.\n"
  );
}

async function callGrokText(messages: { role: string; content: string }[], maxTokens: number): Promise<string> {
  const r = await fetch(XAI_CHAT_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${XAI_API_KEY}` },
    body: JSON.stringify({ model: TEXT_MODEL, messages, temperature: 0.8, max_tokens: maxTokens }),
  });
  if (!r.ok) throw new Error(`LLM ${r.status}: ${await r.text()}`);
  const d = await r.json();
  return d?.choices?.[0]?.message?.content ?? "";
}

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

/// Grok'u "fotoğraf yönetmeni" gibi kullanarak kullanıcının isteğini + alan
/// talimatlarını 6 etiketli alandan oluşan TEK bir görsel-üretim promptuna
/// dönüştürür (CAMERA DETAILS / LIGHTING / SUBJECT / OUTFIT / POSE / LOCATION).
async function composeImagePrompt(opts: {
  appearance: string;
  category: string;
  userPrompt: string;
  hasBaseline: boolean;
  context: string;
}): Promise<string> {
  // Stil kararı HER ZAMAN gerçek `category` alanından — bir görseli hiç
  // görmeyen metin modeline "resme bak, stilini anla" diye bırakılmaz (bkz.
  // baselineConsistencyNote üstteki not). Baseline sadece ek bir tutarlılık
  // notu olarak eklenir.
  const isRealistic = opts.category !== "Fictional";
  const fieldGuidance =
    (isRealistic ? realisticFieldGuidance() : styledFieldGuidance()) +
    (opts.hasBaseline ? baselineConsistencyNote() : "");

  const systemPrompt =
    "You are a professional photo director writing the exact prompt that will be " +
    "fed into an AI image generator to produce ONE image of a specific character.\n\n" +
    `The character: ${opts.appearance}${opts.context}\n\n` +
    "YOU must make every creative decision yourself — never write a vague, " +
    "generic, or unspecified field, and never leave anything for the image " +
    "generator to infer or guess. Every field below must contain concrete, " +
    "specific details, exactly as concrete as the calibration example further " +
    "down.\n\n" +
    "PRIORITY RULE: if the user's request explicitly specifies a detail for any " +
    "field (an exact outfit, pose, location, camera/lighting style, etc.), use " +
    "exactly what they specified for that field — do not change, substitute, or " +
    "reinterpret it. Only invent details for the fields (or parts of fields) the " +
    "user left unspecified.\n\n" +
    "Structure the final prompt using EXACTLY these six labeled fields, each on " +
    "its own line, each followed by short comma-separated descriptive phrases " +
    "(not full sentences):\n\n" +
    fieldGuidance +
    "\nAspect ratio and resolution are already fixed elsewhere by the caller — " +
    `do not mention them in any field. ${NO_TEXT_RULE} ${FRAMING_RULE}\n\n` +
    "Calibration example of the required format and level of specificity " +
    "(different photo, for format reference only — do not reuse its content):\n" +
    FIELD_FORMAT_EXAMPLE +
    "\n\nNow evaluate the user's request below and write the final prompt in " +
    "this exact six-field format, tailored specifically to what they asked for. " +
    "Output ONLY the six labeled lines — no extra commentary, no quotes.\n\n" +
    `The user's request:\n"""\n${opts.userPrompt}\n"""`;

  const composed = await callGrokText(
    [
      { role: "system", content: systemPrompt },
      { role: "user", content: "Write the final image-generation prompt now." },
    ],
    500
  );
  const trimmed = composed.trim();
  return trimmed ? `${trimmed}\n${NO_TEXT_RULE}` : `${opts.userPrompt}\n${NO_TEXT_RULE}`;
}

// Called ONLY when the original image-generation request was rejected
// (typically the image model's own content-policy block on an explicit/NSFW
// ask). Rewrites the SAME six-field prompt into something the image model
// will actually accept — same character/setting/mood, explicit elements
// toned down to suggestive-at-most. This is what lets the bot still send
// a real photo instead of erroring out, paired with a natural in-character
// redirect line (bkz. chat/index.ts IMAGE_REDIRECT_RULE).
async function buildSafeFallbackPrompt(userPrompt: string, rejectedPrompt: string): Promise<string> {
  const raw = await callGrokText(
    [
      {
        role: "system",
        content:
          "You are a photo director. The following exact image-generation " +
          "prompt was REJECTED by the image model's content policy (too " +
          "explicit/NSFW to generate). Rewrite it into a new prompt for the " +
          "SAME character, setting, and mood, but tone down or remove " +
          "whatever made it explicit — keep it tasteful and suggestive at " +
          "most, never nudity or explicit sexual content. Keep the exact " +
          "same labeled-field structure and the same level of concrete, " +
          "specific detail as the rejected prompt. Output ONLY the " +
          "rewritten prompt, nothing else, no commentary.",
      },
      {
        role: "user",
        content: `Original user request: "${userPrompt}"\n\nRejected prompt:\n${rejectedPrompt}`,
      },
    ],
    500
  );
  const trimmed = raw.trim();
  return trimmed ? `${trimmed}\n${NO_TEXT_RULE}` : `${userPrompt}\n${NO_TEXT_RULE}`;
}

async function bytesFromImageResponse(r: Response): Promise<Uint8Array> {
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

/// `baselineImageUrl` varsa (çoğunlukla karakterin profil fotoğrafı) image-to-image
/// /v1/images/edits kullanılır — aynı yüz/saç/cilt tonu korunur, sadece sahne/poz/
/// açı/ışık değişir. Bu, YÜZÜN aynı kalmasını sağlayan TEK mekanizma — metin
/// açıklaması (appearanceContext) asla gerçek bir referans görsel kadar güvenilir
/// değil. Bu yüzden edits başarısız olursa ÖNCE BİR KEZ DAHA denenir (çoğu hata
/// geçici — ağ/5xx) — sadece İKİ deneme de başarısız olursa referanssız düz
/// /v1/images/generations'a düşülür (o zaman yüz KESİNLİKLE tutmaz, bu yüzden
/// son çare). ESKİDEN: tek hata → sessizce referanssız üretime düşüyordu, bu da
/// kullanıcı raporlarındaki "bazen yüz tamamen farklı" hatasının kök nedeniydi.
async function fetchGeneratedImageBytes(prompt: string, baselineImageUrl: string | null): Promise<Uint8Array> {
  if (baselineImageUrl) {
    for (let attempt = 1; attempt <= 2; attempt++) {
      try {
        const r = await fetch(XAI_IMAGE_EDITS_URL, {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: `Bearer ${XAI_API_KEY}` },
          body: JSON.stringify({
            model: IMAGE_MODEL,
            prompt,
            image: { url: baselineImageUrl, type: "image_url" },
            aspect_ratio: IMAGE_ASPECT_RATIO,
            resolution: IMAGE_RESOLUTION,
          }),
        });
        return await bytesFromImageResponse(r);
      } catch (e) {
        console.error(`chat-image edits (baseline) attempt ${attempt} failed:`, String(e));
      }
    }
    console.error("chat-image edits (baseline) failed twice — falling back to referenceless generation, face will NOT match.");
  }

  const r = await fetch(XAI_IMAGE_GENERATIONS_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${XAI_API_KEY}` },
    body: JSON.stringify({
      model: IMAGE_MODEL,
      prompt,
      n: 1,
      aspect_ratio: IMAGE_ASPECT_RATIO,
      resolution: IMAGE_RESOLUTION,
    }),
  });
  return await bytesFromImageResponse(r);
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
    // İstemcinin yerel sohbet geçmişi/özeti — chat/index.ts'nin clientHistory
    // modundakiyle aynı şekle sahip, sadece görsel üretim promptu için kullanılır.
    const history: { role: string; content: string }[] = Array.isArray(b.history) ? b.history : [];
    const summary: string | null = typeof b.summary === "string" ? b.summary : null;
    const currentActivity: string | null = typeof b.currentActivity === "string" ? b.currentActivity : null;
    if (!characterId) return json({ error: "characterId required" }, 400);
    if (!userPrompt) return json({ error: "prompt required" }, 400);

    // Ucuz ön-kontrol — gerçek görsel üretim çağrısını (xAI, $0.02) boşuna
    // yapmamak için. Asıl atomik düşüm görsel BAŞARIYLA üretildikten sonra.
    const { data: preCheckBalance } = await db.from("token_balances").select("balance").eq("user_id", uid).maybeSingle();
    if ((preCheckBalance?.balance ?? 0) < 25) return json({ error: "insufficient_tokens" }, 402);

    const { data: character, error: charErr } = await db
      .from("characters")
      .select("name, profession, tagline, category, builder_selections, photo_url, avatar_url")
      .eq("id", characterId)
      .maybeSingle();
    if (charErr || !character) return json({ error: "character not found" }, 400);

    // "Most of the time use the profile picture" — karakterin mevcut fotoğrafı
    // varsa image-to-image baseline olarak kullanılır (bkz. fetchGeneratedImageBytes).
    const baselineImageUrl: string | null = character.photo_url || character.avatar_url || null;
    // `category` katalog karakterlerinde ÜST SEVİYE bir kolon (builder_selections
    // yalnızca kullanıcı-yaratımı karakterlerde dolu) — bkz. architecture_db.
    const category: string = character.category ?? character.builder_selections?.category ?? "Realistic";

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
      context: conversationContext(history, summary) + currentActivityContext(currentActivity),
    });

    let photoUrl: string;
    let isPrivate = false;
    // `redirected` — the original ask got rejected (content policy) and we
    // regenerated a tamer version instead. Client uses this to ask chat/
    // index.ts for a natural "that's too much right now, but here's this"
    // reply instead of the normal photo-reaction caption (bkz.
    // IMAGE_REDIRECT_RULE) — never just silently swap the photo.
    let redirected = false;
    try {
      const [bytes, privacyResult] = await Promise.all([
        fetchGeneratedImageBytes(imagePrompt, baselineImageUrl),
        classifyPrivacy(imagePrompt),
      ]);
      photoUrl = await uploadGeneratedImage(bytes);
      isPrivate = privacyResult;
    } catch (e) {
      console.error("chat-image generation failed, trying safe fallback prompt:", String(e));
      try {
        const safePrompt = await buildSafeFallbackPrompt(userPrompt, imagePrompt);
        const bytes = await fetchGeneratedImageBytes(safePrompt, baselineImageUrl);
        photoUrl = await uploadGeneratedImage(bytes);
        isPrivate = false; // toned-down by construction
        redirected = true;
      } catch (e2) {
        console.error("chat-image safe fallback also failed:", String(e2));
        return json({ error: "image_generation_failed" }, 502);
      }
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
      is_private: isPrivate,
    });
    if (insErr) console.error("generated_photos insert failed:", insErr.message);

    const charge = await chargeOrReject(uid, 25, "photo");
    return json({ url: photoUrl, redirected, tokenBalance: charge.ok ? charge.balance : undefined });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
