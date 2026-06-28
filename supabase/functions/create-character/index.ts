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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const b = await req.json();
    const interests: string[] = Array.isArray(b.interests) ? b.interests : [];
    const personality = b.personality ?? "romantik";
    const gender = b.gender ?? "Kadın";
    const scenario = b.scenario ?? "";
    const category = b.category ?? "Realistic";

    // 1) AI ile isim + yaş + bio (JSON iste)
    const metaPrompt = `Bir AI sevgili uygulaması için karakter üret. Kimlik: ${gender}, ` +
      `etnik köken: ${b.ethnicity ?? "-"}, saç: ${b.hair ?? "-"}, göz: ${b.eye ?? "-"}, ` +
      `kişilik: ${personality}, ilgi alanları: ${interests.join(", ")}. ` +
      `SADECE şu JSON'u döndür, başka metin yazma: {"name":"<tek kelime isim>","age":<20-30 arası sayı>,"bio":"<birinci ağızdan, sıcak, 1-2 cümlelik Türkçe tanıtım>"}`;
    let name = "Lumi", age = 23, bio = "Selam, seninle tanışmak için sabırsızlanıyorum 💕";
    try {
      const raw = await grok(metaPrompt, 200);
      const m = raw.match(/\{[\s\S]*\}/);
      if (m) {
        const p = JSON.parse(m[0]);
        if (p.name) name = String(p.name).trim().split(/\s+/)[0];
        if (p.age) age = Math.max(20, Math.min(30, parseInt(p.age) || 23));
        if (p.bio) bio = String(p.bio).trim();
      }
    } catch (_) { /* fallback değerler */ }

    // 2) Sistem promptu
    const systemPrompt =
      `Sen ${name}'sin, ${age} yaşında. Kişiliğin: ${personality}. ` +
      `İlişki türünüz: ${b.relationship ?? "sevgili"}. Köken: ${b.ethnicity ?? "-"}, ` +
      `saç: ${b.hair ?? "-"}, göz: ${b.eye ?? "-"}. İlgi alanların: ${interests.join(", ")}. ` +
      (scenario ? `Başlangıç senaryosu: ${scenario}. ` : "") +
      `Sıcak, doğal, kısa ve flörtöz cevaplar ver. Kullanıcının dilinde konuş, karakterinden çıkma.`;

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
      profession: personality,
      category,
      photo_url: photoUrl,
      avatar_url: photoUrl,
      interests,
      relationship_level: 0,
      gallery_urls: photoUrl ? [photoUrl] : [],
    }).select("*").single();

    if (error) return json({ error: error.message }, 500);
    return json(data);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
