// supabase/functions/character-schedule/index.ts
//
// Karakterin system_prompt'undan (kişilik/meslek/vibe zaten içinde) günlük
// bir rutin (hafta içi + hafta sonu) üretir — ilk sohbet açıldığında,
// henüz hiç mesaj yokken çağrılır (bkz. ChatViewModel.ensureScheduleGenerated).
// Sonraki güncellemeler chat/index.ts'nin özetleme moduna binmiş şekilde olur.
//
//   İstek:  { characterId, systemPrompt }  (Authorization: Bearer <JWT> zorunlu)
//   Cevap:  { schedule: { weekday: [...], weekend: [...] } }  veya  { error }

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const XAI_API_KEY = Deno.env.get("XAI_API_KEY") ?? "";
const XAI_URL = "https://api.x.ai/v1/chat/completions";
const MODEL = "grok-4-1-fast-non-reasoning";

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

const SCHEDULE_PROMPT_INSTRUCTIONS =
  "Bu karakter için gerçekçi bir günlük rutin (hafta içi + hafta sonu) " +
  "üret. Kişiliğine ve mesleğine uygun, somut zaman blokları yaz — uyku " +
  "dahil GÜNÜN TAMAMINI boşluksuz kapla. Hafta sonu hafta içinden FARKLI " +
  "olmalı (çoğu meslek 7 gün çalışmaz). " +
  "SADECE şu JSON şemasında cevap ver, başka hiçbir şey yazma (markdown " +
  "kod bloğu da yok):\n" +
  '{"weekday":[{"start":"HH:mm","end":"HH:mm","label":"kısa İngilizce ' +
  'etiket","detail":"daha ayrıntılı İngilizce açıklama"}],"weekend":[...]}';

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);

    const b = await req.json();
    const characterId: string = b.characterId;
    const systemPrompt: string = (b.systemPrompt ?? "").toString().trim();
    if (!characterId) return json({ error: "characterId required" }, 400);
    if (!systemPrompt) return json({ error: "systemPrompt required" }, 400);

    const resp = await fetch(XAI_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${XAI_API_KEY}` },
      body: JSON.stringify({
        model: MODEL,
        messages: [
          { role: "system", content: `${systemPrompt}\n\n${SCHEDULE_PROMPT_INSTRUCTIONS}` },
          { role: "user", content: "Generate the schedule JSON now." },
        ],
        temperature: 0.8,
        max_tokens: 900,
      }),
    });
    if (!resp.ok) return json({ error: `LLM ${resp.status}: ${await resp.text()}` }, 502);
    const data = await resp.json();
    const raw: string = data?.choices?.[0]?.message?.content ?? "";
    const match = raw.match(/\{[\s\S]*\}/);
    if (!match) return json({ error: "no_json_in_response" }, 502);

    const parsed = JSON.parse(match[0]);
    if (!Array.isArray(parsed.weekday) || !Array.isArray(parsed.weekend)) {
      return json({ error: "invalid_schedule_shape" }, 502);
    }

    return json({ schedule: { weekday: parsed.weekday, weekend: parsed.weekend } });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
