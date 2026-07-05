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

// Modelin kendi haline bırakılınca çoğu karakter aynı ortalama saatlere
// (ör. 18:00-19:00 akşam yemeği) yığılıyor — birden fazla bot aynı anda
// "having dinner" gösteriyor. Her üretimde RASTGELE bir "kronotip" seçip
// promptun ZORUNLU bir çıpası yapıyoruz, böylece karakterler arasında
// gerçek yapısal çeşitlilik oluşuyor (sadece LLM sıcaklığına güvenmek yetmedi).
const CHRONOTYPES = [
  "Sabahçı tip: 05:30-06:30 arası uyanır, akşam yemeğini erken (17:30-18:30 " +
  "arası) yer, 21:30-22:30 arası uyur.",
  "Standart mesai tipi: 07:00-07:30 arası uyanır, akşam yemeğini 19:00-20:00 " +
  "arası yer, 23:00 civarı uyur.",
  "Gece kuşu tip: 09:30-10:30 arası uyanır, akşam yemeğini geç (20:30-21:30 " +
  "arası) yer, gece 01:00'den sonra uyur.",
  "Serbest/düzensiz çalışan tipi: gün gün değişen, kalıba uymayan yemek " +
  "saatleri var; geleneksel öğün saatlerini atlayıp ara sıra atıştırabilir, " +
  "uyku saatleri de değişken.",
  "Vardiyalı/alışılmadık saatler tipi: akşam ya da gece çalışır, ana " +
  "öğününü 15:00 veya 22:00 gibi sıra dışı bir saatte yer, günün bir " +
  "bölümünde uyur.",
];

function buildScheduleInstructions(): string {
  const chronotype = CHRONOTYPES[Math.floor(Math.random() * CHRONOTYPES.length)];
  return (
    "Bu karakter için gerçekçi bir günlük rutin (hafta içi + hafta sonu) " +
    "üret. Kişiliğine ve mesleğine uygun, somut zaman blokları yaz — uyku " +
    "dahil GÜNÜN TAMAMINI boşluksuz kapla. Hafta sonu hafta içinden FARKLI " +
    "olmalı (çoğu meslek 7 gün çalışmaz). " +
    `UYANMA/YEMEK/UYKU SAATLERİNİ ŞU KALIBA GÖRE BELİRLE: ${chronotype} ` +
    "Bu kalıp karakterin gerçek mesleğiyle AÇIKÇA çelişmedikçe (ör. gece " +
    "vardiyasında çalışan biri sabahçı olamaz) uygula; çelişirse kalıbın " +
    "RUHUNU (ör. düzensiz/sıra dışı saatler) mesleğe uyarlayarak koru. " +
    "`label` alanı KISA bir DURUM ifadesi olmalı — \"şu an ne yapıyor\" " +
    "sorusuna doğal bir cevap gibi oku (ör. \"Work\" değil \"At work\", " +
    "\"Dinner\" değil \"Having dinner\", \"Commute\" değil \"Commuting home\", " +
    "\"Sleep\" değil \"Asleep\"). " +
    "Her zaman karakterin kendi konuştuğu dilde yaz (bkz. sistem promptundaki " +
    "dil kuralı) — karakter Türkçe konuşuyorsa label/detail de Türkçe olsun, " +
    "asla otomatik İngilizceye geçme. " +
    "SADECE şu JSON şemasında cevap ver, başka hiçbir şey yazma (markdown " +
    "kod bloğu da yok):\n" +
    '{"weekday":[{"start":"HH:mm","end":"HH:mm","label":"kısa durum ' +
    'ifadesi","detail":"daha ayrıntılı açıklama"}],"weekend":[...]}'
  );
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
    const systemPrompt: string = (b.systemPrompt ?? "").toString().trim();
    if (!characterId) return json({ error: "characterId required" }, 400);
    if (!systemPrompt) return json({ error: "systemPrompt required" }, 400);

    const resp = await fetch(XAI_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${XAI_API_KEY}` },
      body: JSON.stringify({
        model: MODEL,
        messages: [
          { role: "system", content: `${systemPrompt}\n\n${buildScheduleInstructions()}` },
          { role: "user", content: "Generate the schedule JSON now." },
        ],
        temperature: 0.8,
        max_tokens: 1500,
      }),
    });
    if (!resp.ok) return json({ error: `LLM ${resp.status}: ${await resp.text()}` }, 502);
    const data = await resp.json();
    const raw: string = data?.choices?.[0]?.message?.content ?? "";
    const match = raw.match(/\{[\s\S]*\}/);
    if (!match) return json({ error: "no_json_in_response" }, 502);

    let parsed: any;
    try {
      parsed = JSON.parse(match[0]);
    } catch (e) {
      return json({ error: `invalid_json: ${String(e)}` }, 502);
    }
    if (!Array.isArray(parsed.weekday) || !Array.isArray(parsed.weekend)) {
      return json({ error: "invalid_schedule_shape" }, 502);
    }

    return json({ schedule: { weekday: parsed.weekday, weekend: parsed.weekend } });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
