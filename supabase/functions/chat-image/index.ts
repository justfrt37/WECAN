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

// Görüntü içinde ASLA yazı/metin/logo olmasın — hem talimat metninde hem de
// modelin unutması ihtimaline karşı final prompt'un sonuna sabit olarak eklenir.
const NO_TEXT_RULE =
  "The image must contain absolutely no text, letters, numbers, captions, " +
  "subtitles, watermarks, logos, or writing of any kind anywhere in the frame.";

function appearanceContext(opts: {
  name: string;
  profession: string | null;
  builderSelections: BuilderSelections | null;
}): string {
  const bs = opts.builderSelections;
  if (bs && (bs.hairstyle || bs.hair_color || bs.eye_shape || bs.eye_color)) {
    return `${opts.name}, a person with ${(bs.hairstyle ?? "").toLowerCase()} ` +
      `${(bs.hair_color ?? "").toLowerCase()} hair, ${(bs.eye_shape ?? "").toLowerCase()} ` +
      `${(bs.eye_color ?? "").toLowerCase()} eyes, ${(bs.nose_shape ?? "").toLowerCase()} nose, ` +
      `${(bs.skin_tone ?? "").toLowerCase()} skin tone`;
  }
  // Katalog karakteri — kayıtlı görünüm alanı yok, en iyi ihtimalle isim/meslek.
  return `${opts.name}${opts.profession ? `, a ${opts.profession.toLowerCase()}` : ""}`;
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

// Gerçekçi (Realistic / kayıt yok = varsayılan) kategori için alan-bazlı
// talimat — telefon modeli, cilt dokusu, ISO/grain, flaş CAMERA DETAILS'a girer.
function realisticFieldGuidance(hasBaseline: boolean): string {
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
    "skin — plus the expression implied by the user's request.\n" +
    "OUTFIT: exactly what the character is wearing, specific enough to " +
    "visualize (garment type, fit, color) — infer something fitting if the " +
    "user didn't specify.\n" +
    "POSE: exactly how the character is positioned — where their arms and legs " +
    "are, their posture, what they're looking at.\n" +
    "LOCATION: the specific background and setting — be concrete about what's " +
    "visible around the character.\n" +
    (hasBaseline
      ? "A baseline reference photo of this exact person is attached — keep the " +
        "same face, hair, and skin tone as the reference; only change SUBJECT's " +
        "expression, OUTFIT, POSE, and LOCATION per the user's request.\n"
      : "")
  );
}

// Anime/Fantasy/Sci-Fi kategorileri için aynı 6 alan, ama CAMERA DETAILS
// yerine sanat stili/render tekniği; fotoğraf-gerçekçiliği (telefon/ISO/flaş)
// burada geçerli değil.
function styledFieldGuidance(category: string, hasBaseline: boolean): string {
  const styleCue: Record<string, string> = {
    Anime: "clean anime illustration line art, vibrant cel-shaded coloring, detailed shading",
    Fantasy: "fantasy digital painting, magical atmosphere, painterly brushwork detail",
    "Sci-Fi": "sci-fi digital art, futuristic aesthetic, cinematic rim lighting",
  };
  const style = styleCue[category] ?? styleCue.Anime;
  return (
    `CAMERA DETAILS: ${style} — name this style and rendering technique ` +
    "explicitly instead of a camera/phone.\n" +
    "LIGHTING: the specific light source, quality, and overall color palette " +
    "matching the scene and art style.\n" +
    "SUBJECT: the character's appearance (given below), plus the expression " +
    "implied by the user's request.\n" +
    "OUTFIT: exactly what the character is wearing, specific enough to " +
    "visualize — infer something fitting if the user didn't specify.\n" +
    "POSE: exactly how the character is positioned — where their arms and legs " +
    "are, their posture, what they're looking at.\n" +
    "LOCATION: the specific background and setting.\n" +
    (hasBaseline
      ? "A baseline reference image of this exact character is attached — keep " +
        "the same face, hair, and outfit style as the reference; only change " +
        "SUBJECT's expression, OUTFIT, POSE, and LOCATION per the user's request.\n"
      : "")
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

/// Grok'u "fotoğraf yönetmeni" gibi kullanarak kullanıcının isteğini + alan
/// talimatlarını 6 etiketli alandan oluşan TEK bir görsel-üretim promptuna
/// dönüştürür (CAMERA DETAILS / LIGHTING / SUBJECT / OUTFIT / POSE / LOCATION).
async function composeImagePrompt(opts: {
  appearance: string;
  category: string;
  userPrompt: string;
  hasBaseline: boolean;
}): Promise<string> {
  const isRealistic = opts.category !== "Anime" && opts.category !== "Fantasy" && opts.category !== "Sci-Fi";
  const fieldGuidance = isRealistic
    ? realisticFieldGuidance(opts.hasBaseline)
    : styledFieldGuidance(opts.category, opts.hasBaseline);

  const systemPrompt =
    "You are a professional photo director writing the exact prompt that will be " +
    "fed into an AI image generator to produce ONE image of a specific character.\n\n" +
    `The character: ${opts.appearance}\n\n` +
    "YOU must make every creative decision yourself — never write a vague, " +
    "generic, or unspecified field, and never leave anything for the image " +
    "generator to infer or guess. Every field below must contain concrete, " +
    "specific details, exactly as concrete as the calibration example further " +
    "down.\n\n" +
    "Structure the final prompt using EXACTLY these six labeled fields, each on " +
    "its own line, each followed by short comma-separated descriptive phrases " +
    "(not full sentences):\n\n" +
    fieldGuidance +
    "\nAspect ratio and resolution are already fixed elsewhere by the caller — " +
    `do not mention them in any field. ${NO_TEXT_RULE}\n\n` +
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
/// açı/ışık değişir. Edits başarısız olursa (desteklenmeyen format vb.) TEK SEFER
/// düz /v1/images/generations'a düşer.
async function fetchGeneratedImageBytes(prompt: string, baselineImageUrl: string | null): Promise<Uint8Array> {
  if (baselineImageUrl) {
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
      console.error("chat-image edits (baseline) failed, falling back to generations:", String(e));
    }
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
    if (!characterId) return json({ error: "characterId required" }, 400);
    if (!userPrompt) return json({ error: "prompt required" }, 400);

    const { data: character, error: charErr } = await db
      .from("characters")
      .select("name, profession, tagline, builder_selections, photo_url, avatar_url")
      .eq("id", characterId)
      .maybeSingle();
    if (charErr || !character) return json({ error: "character not found" }, 400);

    // "Most of the time use the profile picture" — karakterin mevcut fotoğrafı
    // varsa image-to-image baseline olarak kullanılır (bkz. fetchGeneratedImageBytes).
    const baselineImageUrl: string | null = character.photo_url || character.avatar_url || null;
    const category: string = character.builder_selections?.category ?? "Realistic";

    let photoUrl: string;
    try {
      const imagePrompt = await composeImagePrompt({
        appearance: appearanceContext({
          name: character.name,
          profession: character.profession,
          builderSelections: character.builder_selections ?? null,
        }),
        category,
        userPrompt,
        hasBaseline: baselineImageUrl !== null,
      });
      const bytes = await fetchGeneratedImageBytes(imagePrompt, baselineImageUrl);
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
