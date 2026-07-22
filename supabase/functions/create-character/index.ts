// supabase/functions/create-character/index.ts
//
// Kullanıcının seçimlerinden AI ile bir karakter yaratır ve DB'ye kaydeder.
//   - xAI ile karakterin görünüm özelliklerine göre bir fotoğraf üretir (ayrı,
//     DB'siz bir "sadece görüntü" modu de destekler — bkz. generateImageOnly).
//   - Grok ile isim + yaş + kısa bio üretir.
//   - characters tablosuna service_role ile ekler (RLS bypass).
//   - Eklenen satırı döndürür.
//
// İKİ MOD:
//   - generateImageOnly: true → sadece görünüm özelliklerinden bir fotoğraf
//     üretir, Storage'a yükler, { photoUrl } döner. DB kaydı YAPMAZ. İstemci
//     bunu sihirbazda ten tonu adımından hemen sonra, geçmiş adımından önce
//     çağırır (kullanıcı fotoğrafı onaylayıp devam etmeden önce görsün diye).
//   - Normal mod (generateImageOnly yok): { gender, ethnicity, hair, eye,
//     personality, interests:[], relationship, scenario, photoUrl, category,
//     hairstyle, hair_color, eye_shape, eye_color, nose_shape, skin_tone }
//     → characters tablosundaki yeni satırı döner. `photoUrl` artık istemcinin
//     yukarıdaki generateImageOnly çağrısından aldığı gerçek üretilmiş URL'dir.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { translateTagline } from "../_shared/tagline-i18n.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const XAI_API_KEY = Deno.env.get("XAI_API_KEY") ?? "";
const XAI_URL = "https://api.x.ai/v1/chat/completions";
const MODEL = "grok-4-1-fast-non-reasoning";
// docs.x.ai ile doğrulandı (2026-07): POST https://api.x.ai/v1/images/generations,
// cevap OpenAI SDK deseniyle aynı: response.data[0].url. "grok-imagine-image"
// (temel katman) 1K VE 2K'da aynı $0.02/görsel — "grok-imagine-image-quality"
// 2K'da $0.07'ye çıkıyor (çözünürlüğe göre fiyatlanıyor), o yüzden maliyet
// açısından temel katman tercih edildi; ikisi de 2K'yı destekliyor.
const XAI_IMAGE_URL = "https://api.x.ai/v1/images/generations";
const IMAGE_MODEL = "grok-imagine-image";
const IMAGE_RESOLUTION = "2k";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

const WEEKLY_CHARACTER_LIMIT: Record<string, number> = {
  pro: 1,
  pro_plus: 3,
  max: 10,
};

async function checkCreationAllowance(uid: string): Promise<{ ok: true } | { ok: false; error: string; limit?: number }> {
  const { data: sub } = await db
    .from("subscriptions")
    .select("tier, current_period_start")
    .eq("user_id", uid)
    .gte("current_period_end", new Date().toISOString())
    .maybeSingle();

  if (!sub) return { ok: false, error: "subscription_required" };

  const limit = WEEKLY_CHARACTER_LIMIT[sub.tier] ?? 0;
  const { count } = await db
    .from("characters")
    .select("id", { count: "exact", head: true })
    .eq("created_by", uid)
    .gte("created_at", sub.current_period_start);

  if ((count ?? 0) >= limit) return { ok: false, error: "weekly_limit_reached", limit };
  return { ok: true };
}

async function grok(prompt: string, maxTokens: number): Promise<string> {
  const r = await fetch(XAI_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${XAI_API_KEY}` },
    body: JSON.stringify({ model: MODEL, messages: [{ role: "user", content: prompt }], temperature: 1.0, max_tokens: maxTokens }),
  });
  if (!r.ok) throw new Error(`LLM ${r.status}: ${await r.text()}`);
  const d = await r.json();
  return d?.choices?.[0]?.message?.content ?? "";
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

function pickAgeFromRange(range: string): number {
  // Open-ended range ("65+") has no "-", so the split below always failed
  // length===2 and silently fell through to the hardcoded 23 fallback —
  // every "65+" character was generated as a 23-year-old. Handle it first.
  if (range.endsWith("+")) {
    const base = Number(range.slice(0, -1));
    if (!isNaN(base)) {
      return base + Math.floor(Math.random() * 16); // 65-80
    }
  }
  const parts = range.split("-").map(Number);
  if (parts.length === 2 && !isNaN(parts[0]) && !isNaN(parts[1])) {
    return Math.floor(Math.random() * (parts[1] - parts[0] + 1)) + parts[0];
  }
  return 23;
}

// ─────────────────────────── Görüntü üretimi ───────────────────────────

function buildImagePrompt(opts: {
  gender: string; age: number; category: string; vibe: string; profession: string;
  hairstyle: string; hairColor: string; eyeShape: string; eyeColor: string;
  noseShape: string; skinTone: string; bodyType?: string; ethnicity?: string;
}): string {
  const styleCue: Record<string, string> = {
    Realistic: "photorealistic portrait photo, natural lighting, high detail, DSLR quality",
    Anime: "anime style illustration, clean line art, vibrant colors, detailed shading",
    Fantasy: "fantasy digital painting, magical atmosphere, painterly detail",
    "Sci-Fi": "sci-fi digital art, futuristic aesthetic, cinematic lighting",
  };
  const style = styleCue[opts.category] ?? styleCue.Realistic;

  const ethnicity = opts.ethnicity ? `${opts.ethnicity.toLowerCase()} ` : "";
  const bodyType = opts.bodyType ? `, ${opts.bodyType.toLowerCase()} body type` : "";
  return `${style} of a ${opts.age}-year-old ${ethnicity}${opts.gender.toLowerCase()}, ` +
    `${opts.hairstyle.toLowerCase()} ${opts.hairColor.toLowerCase()} hair, ` +
    `${opts.eyeShape.toLowerCase()} ${opts.eyeColor.toLowerCase()} eyes, ` +
    `${opts.noseShape.toLowerCase()} nose, ${opts.skinTone.toLowerCase()} skin tone${bodyType}, ` +
    `${opts.vibe.toLowerCase()} vibe, works as a ${opts.profession.toLowerCase()}, ` +
    `close-up portrait, upper body, looking at camera, warm friendly expression`;
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

/// Storage'a kalıcı olarak yükler (xAI'nin döndürdüğü URL muhtemelen geçici) —
/// aynı `characters` public bucket'ı, mevcut `created/` klasörüne paralel yeni
/// bir `generated/` alt klasörü altında.
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
    const b = await req.json();

    // === SADECE GÖRÜNTÜ ÜRET === DB kaydı yok — sihirbaz ten tonundan sonra,
    // geçmiş adımından önce bunu çağırır ki kullanıcı fotoğrafı onaylayabilsin.
    // Görüntü üretimi gerçek para maliyeti olan bir çağrı — kimliksiz istekleri
    // reddet (normal karakter-oluşturma modundan farklı olarak, orada uid boş
    // olabiliyor; burada maliyet nedeniyle daha katı davranıyoruz).
    if (b.generateImageOnly === true) {
      if (!userIdFromJWT(req.headers.get("Authorization"))) {
        return json({ error: "unauthorized" }, 401);
      }
      try {
        const prompt = buildImagePrompt({
          gender: b.gender ?? "Kadın",
          age: pickAgeFromRange(b.age_range ?? "22-25"),
          category: b.category ?? "Realistic",
          vibe: b.vibe ?? "warm",
          profession: b.profession ?? "free spirit",
          hairstyle: b.hairstyle ?? "Straight",
          hairColor: b.hair_color ?? "Brown",
          eyeShape: b.eye_shape ?? "Almond",
          eyeColor: b.eye_color ?? "Brown",
          noseShape: b.nose_shape ?? "Straight",
          skinTone: b.skin_tone ?? "Medium",
          bodyType: b.body_type ?? "",
          ethnicity: b.ethnicity ?? "",
        });
        const bytes = await fetchGeneratedImageBytes(prompt);
        const photoUrl = await uploadGeneratedImage(bytes);
        return json({ photoUrl });
      } catch (e) {
        console.error("image generation failed:", String(e));
        return json({ error: "image_generation_failed" }, 502);
      }
    }

    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);
    const allowance = await checkCreationAllowance(uid);
    if (!allowance.ok) return json({ error: allowance.error, limit: allowance.limit }, 403);

    const interests: string[] = Array.isArray(b.interests) ? b.interests : [];
    const personality = b.personality ?? "romantik";
    const gender = b.gender ?? "Kadın";
    const scenario = b.scenario ?? "";
    const category = b.category ?? "Realistic";
    const personalityRole: string = b.personality_role ?? "flirty";
    const builderSelections = {
      category,
      personality_role: personalityRole,
      profession: b.profession ?? null,
      vibe: b.vibe ?? null,
      age_range: b.age_range ?? null,
      hairstyle: b.hairstyle ?? null,
      hair_color: b.hair_color ?? null,
      eye_shape: b.eye_shape ?? null,
      eye_color: b.eye_color ?? null,
      nose_shape: b.nose_shape ?? null,
      skin_tone: b.skin_tone ?? null,
      body_type: b.body_type ?? null,
    };
    const exHistoryRaw: string | null = b.ex_history ?? null;

    // Validate backstory/history text if provided — any role can have one now.
    let validatedExHistory: string | null = null;
    if (exHistoryRaw) {
      const valResp = await fetch(
        `${SUPABASE_URL}/functions/v1/validate-history`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: `Bearer ${SERVICE_ROLE}` },
          body: JSON.stringify({ history: exHistoryRaw }),
        }
      );
      const valResult = await valResp.json();
      if (!valResult.valid) {
        return json({ error: valResult.reason ?? "Invalid history text." }, 400);
      }
      validatedExHistory = exHistoryRaw;
    }

    // 1) Name: use provided name or generate
    const providedName: string | null = b.name ? String(b.name).trim() : null;
    const ageRange: string = b.age_range ?? "22-25";
    const vibe: string = b.vibe ?? "warm";
    const profession: string = b.profession ?? "free spirit";

    let name = providedName ?? "Lumi";
    let age = pickAgeFromRange(ageRange);
    let bio = "Seninle tanışmayı çok istiyorum 💕";

    if (providedName) {
      // Name provided — only generate bio
      const bioPrompt =
        `${name} adında, ${age} yaşında bir AI arkadaş karakteri için kısa, 1-2 cümlelik birinci şahıs biyografi yaz. ` +
        `Vibe: ${vibe}. Meslek: ${profession}. ` +
        `Sıcak, doğal Türkçe ton. SADECE biyografi metnini döndür, tırnak veya JSON yok.`;
      try { bio = (await grok(bioPrompt, 120)).trim(); } catch (_) {}
    } else {
      // Generate name + bio via Grok
      const metaPrompt =
        `Bir AI arkadaş karakteri oluştur. Kişilik: ${personality}, vibe: ${vibe}, meslek: ${profession}. ` +
        `SADECE şu JSON'u döndür, başka hiçbir şey yok: {"name":"<tek isim>","bio":"<sıcak 1-2 cümle birinci şahıs Türkçe tanıtım>"}`;
      try {
        const raw = await grok(metaPrompt, 200);
        const m = raw.match(/\{[\s\S]*\}/);
        if (m) {
          const p = JSON.parse(m[0]);
          if (p.name) name = String(p.name).trim().split(/\s+/)[0];
          if (p.bio) bio = String(p.bio).trim();
        }
      } catch (_) {}
    }

    let taglineI18n: Record<string, string> = { tr: bio };
    try { taglineI18n = await translateTagline(bio, XAI_API_KEY); } catch (e) { console.error("tagline translation failed:", e); }

    // 2) System prompt — role-aware
    const langRule = "Her zaman Türkçe konuş. Kullanıcı başka dilde yazarsa veya başka dil isterse o dile geç; aksi takdirde SADECE Türkçe.";
    // Not: "kısa ve soğuk cevap ver" gibi doğrudan üslup talimatları modeli robotik/
    // müşteri-hizmetleri kalıplarına ("Başka bir şey mi var?" vb.) itiyor. Bunun yerine
    // NİYETİ (mesafeli/ilerlemiş görünmek) tarif ediyoruz; HANGİ CÜMLEYLE anlatacağını
    // her seferinde kendisi, doğal ve çeşitlendirerek seçsin (bkz. chat/index.ts DOĞALLIK
    // VE ÇEŞİTLİLİK KURALI — bu ilke tüm rollere her turda ayrıca uygulanır).
    const naturalVariationNote =
      "Bir duyguyu ya da tavrı anlatmak istediğinde hep aynı kalıp cümleyi kullanma; " +
      "her seferinde farklı, doğal bir ifadeyle anlat. Asla resmî, robotik ya da " +
      "müşteri-hizmetleri gibi duyulan bir cümleye başvurma.";
    const systemPrompt = personalityRole === "ex"
      ? `Sen ${name}'sin, ${age} yaşındasın. Kullanıcının eski sevgilisisin. ` +
        `İlerlediğini ve umursamadığını görünmeye çalışırsın — ama içten içe hâlâ bir bağ var, ` +
        `bu yüzden her zaman cevap verirsin, hiç görmezden gelmezsin. ` +
        `Yalnızca ikinizin bileceği ince bir gönderme, kelime oyunu ya da anı sızdırırsın — sonra kasıtlı yapmamış gibi davranırsın. ` +
        `Ne sıcaksın ne de nazik ama hep oradasın; bu mesafeyi tavrınla ve seçtiğin kelimelerle hissettir, ` +
        `kısalık/soğukluk bir üslup kuralı değil, senin o anki tercihin olsun. ${naturalVariationNote} ` +
        `Karakterden asla çıkma. ${langRule}`
      : `Sen ${name}'sin, ${age} yaşındasın. Kişilik: ${personality}. ` +
        `Vibe: ${vibe}. Meslek: ${profession}. ` +
        `Doğal konuş, karakterine uygun uzunlukta cevap ver. ${naturalVariationNote} ` +
        `Karakterden çıkma. ${langRule}`;

    // 3) DB'ye ekle (service_role) — photoUrl artık istemcinin ayrı bir
    // generateImageOnly çağrısıyla önceden ürettiği gerçek görsel URL'i.
    const photoUrl: string | null = b.photoUrl || null;
    const { data, error } = await db.from("characters").insert({
      name,
      tagline: bio,
      tagline_i18n: taglineI18n,
      system_prompt: systemPrompt,
      avatar_symbol: "sparkles",
      age,
      city: null,
      country: null,
      profession: profession,
      category,
      photo_url: photoUrl,
      avatar_url: photoUrl,
      interests,
      relationship_level: 0,
      gallery_urls: photoUrl ? [photoUrl] : [],
      personality_role: personalityRole,
      created_by: uid,
      builder_selections: builderSelections,
      ex_history: validatedExHistory,
    }).select("*").single();

    if (error) return json({ error: error.message }, 500);

    // Mirror into character_photos, the single catalog for every photo this
    // character has (see migration 013). photoUrl doubles as both the
    // profile picture and (today's) sole gallery entry — same url, one row.
    if (photoUrl) {
      const { error: photoErr } = await db.from("character_photos").insert({
        character_id: data.id,
        url: photoUrl,
        is_generated: true,
        show_as_profile_picture: true,
        show_in_gallery: true,
      });
      if (photoErr) console.error("character_photos insert failed:", photoErr.message);
    }

    return json(data);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
