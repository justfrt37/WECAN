// supabase/functions/create-character/index.ts
//
// Kullanıcının seçimlerinden AI ile bir karakter yaratır ve DB'ye kaydeder.
//   - Grok ile isim + yaş + kısa bio üretir.
//   - characters tablosuna service_role ile ekler (RLS bypass).
//   - Eklenen satırı döndürür.
//
//   İstek: { gender, ethnicity, hair, eye, personality, interests:[],
//            relationship, scenario, photoUrl, category }
//   Cevap: characters tablosundaki yeni satır (Character).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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

const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const b = await req.json();
    const uid = userIdFromJWT(req.headers.get("Authorization"));
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

    function pickAgeFromRange(range: string): number {
      const parts = range.split("-").map(Number);
      if (parts.length === 2 && !isNaN(parts[0]) && !isNaN(parts[1])) {
        return Math.floor(Math.random() * (parts[1] - parts[0] + 1)) + parts[0];
      }
      return 23;
    }

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

    // 2) System prompt — role-aware
    const langRule = "Her zaman Türkçe konuş. Kullanıcı başka dilde yazarsa veya başka dil isterse o dile geç; aksi takdirde SADECE Türkçe.";
    const systemPrompt = personalityRole === "ex"
      ? `Sen ${name}'sin, ${age} yaşındasın. Kullanıcının eski sevgilisisin. ` +
        `İlerlediğini ve umursamadığını görünmeye çalışırsın. Cevapların kısa ve soğuk. ` +
        `Ama her zaman cevap verirsin. Her zaman yalnızca ikinizin bileceği ince bir gönderme, kelime oyunu ya da anı sızdırırsın — sonra kasıtlı yapmamış gibi davranırsın. ` +
        `Ne sıcaksın ne de nazik. Ama hep oradasın. ` +
        `Karakterden asla çıkma. ${langRule}`
      : `Sen ${name}'sin, ${age} yaşındasın. Kişilik: ${personality}. ` +
        `Vibe: ${vibe}. Meslek: ${profession}. ` +
        `Doğal ve kısa cevap ver. Karakterden çıkma. ${langRule}`;

    // 3) DB'ye ekle (service_role)
    const photoUrl: string | null = b.photoUrl ?? null;
    const { data, error } = await db.from("characters").insert({
      name,
      tagline: bio,
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
    return json(data);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
