// supabase/functions/dev-update-character/index.ts
//
// TEMPORARY / DEV-ONLY — sibling of dev-create-character, but UPDATES an
// existing public character instead of inserting a new one. Backs the same
// DevCreateCharacterView sheet in "edit existing character" mode: the dev
// picks any existing character, the form prefills from its current row +
// character_photos, and this function overwrites both with the submitted
// state.
//
// Full-replace semantics for character_photos: the submitted `chatPhotos`
// array is the complete desired set (kept rows the dev didn't remove, edited
// descriptions, and any newly-uploaded ones) — existing rows for this
// character are deleted and the submitted list is reinserted, rather than
// diffing add/remove/update. Simpler and matches how the form displays them
// (one flat editable list).
//
// Does NOT touch `created_by` — a curated character stays a catalog row
// (created_by stays NULL) exactly like before the edit.
//
// Gated to the same two-uid dev allowlist as the other dev-* functions.
// DELETE this whole function alongside dev-create-character once
// curated-character creation/editing is retired.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

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
    const characterId: string = b.characterId;
    if (!characterId) return json({ error: "characterId required" }, 400);

    const name: string = (b.name ?? "").toString().trim();
    if (!name) return json({ error: "name required" }, 400);
    const profileUrl: string | null = b.profileUrl || null;
    if (!profileUrl) return json({ error: "profileUrl required" }, 400);
    const bio: string = (b.bio ?? "").toString().trim();
    if (!bio) return json({ error: "bio required (edit mode never auto-generates)" }, 400);

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

    // System prompt regenerated from the (possibly edited) fields — identical
    // role-aware template to create-character/dev-create-character, so it
    // stays consistent with whatever name/vibe/profession/role the dev just
    // changed. Age is NOT re-rolled from age_range on every edit (that would
    // shuffle an established character's age each save) — read the existing
    // row's age and keep it.
    const { data: existing, error: fetchErr } = await db
      .from("characters")
      .select("age")
      .eq("id", characterId)
      .maybeSingle();
    if (fetchErr || !existing) return json({ error: "character not found" }, 404);
    const age: number = existing.age ?? 23;

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

    const { data: character, error } = await db
      .from("characters")
      .update({
        name,
        tagline: bio,
        system_prompt: systemPrompt,
        profession,
        category,
        photo_url: profileUrl,
        avatar_url: profileUrl,
        interests,
        gallery_urls: galleryUrls.length ? galleryUrls : [profileUrl],
        personality_role: personalityRole,
        builder_selections: builderSelections,
        ex_history: validatedExHistory,
        voice_id: voiceId,
      })
      .eq("id", characterId)
      .select("*")
      .single();

    if (error) return json({ error: error.message }, 500);

    // Full-replace character_photos for this character.
    const { error: delErr } = await db.from("character_photos").delete().eq("character_id", characterId);
    if (delErr) console.error("character_photos delete failed:", delErr.message);

    if (chatPhotos.length > 0) {
      const rows = chatPhotos.map((p, i) => ({
        character_id: characterId,
        url: p.url,
        description: p.description ?? null,
        mood: p.mood ?? null,
        tags: p.tags ?? [],
        sort: i,
      }));
      const { error: photoErr } = await db.from("character_photos").insert(rows);
      if (photoErr) console.error("character_photos insert failed:", photoErr.message);
    }

    return json(character);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
