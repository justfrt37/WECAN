// supabase/functions/dev-create-character/index.ts
//
// TEMPORARY / DEV-ONLY — backs the Profile tab's "DEV: Create Curated
// Character" panel. Like supabase/functions/create-character/index.ts but:
//   - `created_by` is left NULL (catalog row — same as seed characters),
//     so it's visible to every user (characters_public_read RLS) and does
//     NOT count against any user's weekly character-creation limit.
//   - photoUrl/galleryUrls/chatPhotos come from real device photos already
//     uploaded via dev-upload-image (no xAI image generation here).
//   - chatPhotos become `character_photos` rows with a dev-written
//     `description` — chat-image/index.ts uses those descriptions to decide
//     whether an uploaded photo already satisfies a photo request instead of
//     generating a new one.
//   - optional `voiceId` is stored on `characters.voice_id` (per-character
//     ElevenLabs override; NULL keeps the existing role+vibe auto-map).
//
// Gated to the same two-uid dev allowlist as dev-upload-image/dev-list-voices.
// DELETE this whole function (and the character_photos.description /
// characters.voice_id columns' consumers) once curated-character creation is
// retired.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { translateTagline } from "../_shared/tagline-i18n.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const XAI_API_KEY = Deno.env.get("XAI_API_KEY") ?? "";
const XAI_URL = "https://api.x.ai/v1/chat/completions";
const MODEL = "grok-4-1-fast-non-reasoning";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

const DEV_UIDS = new Set([
  "81565166-be1e-48f6-a580-3f8b78e378e2",
  "9bd6b9c6-a498-42dd-a337-33a70100117f",
]);

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

function pickAgeFromRange(range: string): number {
  if (range.endsWith("+")) {
    const base = Number(range.slice(0, -1));
    if (!isNaN(base)) return base + Math.floor(Math.random() * 16); // 65-80
  }
  const parts = range.split("-").map(Number);
  if (parts.length === 2 && !isNaN(parts[0]) && !isNaN(parts[1])) {
    return Math.floor(Math.random() * (parts[1] - parts[0] + 1)) + parts[0];
  }
  return 23;
}

interface ChatPhotoInput {
  url: string;
  description: string;
  mood?: string;
  tags?: string[];
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid || !DEV_UIDS.has(uid)) return json({ error: "forbidden" }, 403);

    const b = await req.json();

    const name: string = (b.name ?? "").toString().trim();
    if (!name) return json({ error: "name required" }, 400);
    const profileUrl: string | null = b.profileUrl || null;
    if (!profileUrl) return json({ error: "profileUrl required" }, 400);

    const galleryUrls: string[] = Array.isArray(b.galleryUrls) ? b.galleryUrls : [];
    const chatPhotos: ChatPhotoInput[] = Array.isArray(b.chatPhotos) ? b.chatPhotos : [];
    const voiceId: string | null = b.voiceId || null;
    const interests: string[] = Array.isArray(b.interests) ? b.interests : [];

    const category: string = b.category ?? "Realistic";
    const personalityRole: string = b.personality_role ?? "flirty";
    const personality: string = b.personality ?? "romantik";
    const ageRange: string = b.age_range ?? "22-25";
    const vibe: string = b.vibe ?? "warm";
    const profession: string = b.profession ?? "free spirit";
    const age = pickAgeFromRange(ageRange);

    const builderSelections = {
      category,
      personality_role: personalityRole,
      profession,
      vibe,
      age_range: ageRange,
      hairstyle: b.hairstyle ?? null,
      hair_color: b.hair_color ?? null,
      eye_shape: b.eye_shape ?? null,
      eye_color: b.eye_color ?? null,
      nose_shape: b.nose_shape ?? null,
      skin_tone: b.skin_tone ?? null,
      body_type: b.body_type ?? null,
    };

    // Backstory validation reuses the exact same guard as the normal
    // creation flow — a dev-authored ex_history still goes through the
    // jailbreak/injection classifier.
    const exHistoryRaw: string | null = b.ex_history ?? null;
    let validatedExHistory: string | null = null;
    if (exHistoryRaw) {
      const valResp = await fetch(`${SUPABASE_URL}/functions/v1/validate-history`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${SERVICE_ROLE}` },
        body: JSON.stringify({ history: exHistoryRaw }),
      });
      const valResult = await valResp.json();
      if (!valResult.valid) return json({ error: valResult.reason ?? "Invalid history text." }, 400);
      validatedExHistory = exHistoryRaw;
    }

    // Bio: dev can supply one directly, else generate like the normal flow.
    let bio: string = (b.bio ?? "").toString().trim();
    if (!bio) {
      const bioPrompt =
        `${name} adında, ${age} yaşında bir AI arkadaş karakteri için kısa, 1-2 cümlelik birinci şahıs biyografi yaz. ` +
        `Vibe: ${vibe}. Meslek: ${profession}. ` +
        `Sıcak, doğal Türkçe ton. SADECE biyografi metnini döndür, tırnak veya JSON yok.`;
      try { bio = (await grok(bioPrompt, 120)).trim(); } catch (_) { bio = "Seninle tanışmayı çok istiyorum 💕"; }
    }

    let taglineI18n: Record<string, string> = { tr: bio };
    try { taglineI18n = await translateTagline(bio, XAI_API_KEY); } catch (e) { console.error("tagline translation failed:", e); }

    // System prompt — identical role-aware logic to create-character/index.ts.
    const langRule = "Her zaman Türkçe konuş. Kullanıcı başka dilde yazarsa veya başka dil isterse o dile geç; aksi takdirde SADECE Türkçe.";
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

    // created_by left NULL on purpose — catalog row, visible to everyone via
    // the existing characters_public_read RLS policy, doesn't touch the
    // per-user weekly creation limit.
    const { data: character, error } = await db.from("characters").insert({
      name,
      tagline: bio,
      tagline_i18n: taglineI18n,
      system_prompt: systemPrompt,
      avatar_symbol: "sparkles",
      age,
      city: null,
      country: null,
      profession,
      category,
      photo_url: profileUrl,
      avatar_url: profileUrl,
      interests,
      relationship_level: 0,
      gallery_urls: galleryUrls.length ? galleryUrls : [profileUrl],
      personality_role: personalityRole,
      created_by: null,
      builder_selections: builderSelections,
      ex_history: validatedExHistory,
      voice_id: voiceId,
    }).select("*").single();

    if (error) return json({ error: error.message }, 500);

    // character_photos is the single catalog for every photo this character
    // has — chat pool, profile picture, and gallery — see migration 013.
    const photoRows: Record<string, unknown>[] = [];

    for (const p of chatPhotos) {
      photoRows.push({
        character_id: character.id,
        url: p.url,
        description: p.description ?? null,
        mood: p.mood ?? null,
        tags: p.tags ?? [],
        sort: photoRows.length,
        is_uploaded: true,
        show_in_chat: true,
      });
    }

    photoRows.push({
      character_id: character.id,
      url: profileUrl,
      is_uploaded: true,
      show_as_profile_picture: true,
    });

    const galleryList = galleryUrls.length ? galleryUrls : [profileUrl];
    for (const [i, url] of galleryList.entries()) {
      photoRows.push({
        character_id: character.id,
        url,
        sort: i,
        is_uploaded: true,
        show_in_gallery: true,
      });
    }

    const { error: photoErr } = await db.from("character_photos").insert(photoRows);
    if (photoErr) console.error("character_photos insert failed:", photoErr.message);

    return json(character);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
