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
