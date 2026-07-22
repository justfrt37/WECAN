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

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const XAI_API_KEY = Deno.env.get("XAI_API_KEY") ?? "";
const XAI_URL = "https://api.x.ai/v1/chat/completions";
const MODEL = "grok-4-1-fast-non-reasoning";

// Üretilen rutini KALICI yazmak için (service-role → RLS baypas).
const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

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
// Bu bir "geç saatlere kadar sohbet" uygulaması — HİÇBİR karakter gece 01:00'den
// ÖNCE yatmamalı (kullanıcı talebi, 2026-07). Eskiden bazı kronotipler
// 21:30/23:00 gibi erken uyku saatleri veriyordu, bu yüzden aktif sohbet
// sırasında bile botlar "ben yatıyorum" diyordu. Tüm uyku saatleri 01:00
// sonrasına çekildi; uyanma saatleri gerçekçilik için aynı kaldı (bkz.
// buildScheduleInstructions'daki ek sabit taban çizgisi de).
const CHRONOTYPES = [
  "Sabahçı ama geç yatan tip: 05:30-06:30 arası uyanır, akşam yemeğini erken " +
  "(17:30-18:30 arası) yer, gece 01:00-01:30 arası uyur.",
  "Standart mesai tipi: 07:00-07:30 arası uyanır, akşam yemeğini 19:00-20:00 " +
  "arası yer, gece 01:30-02:00 arası uyur.",
  "Gece kuşu tip: 09:30-10:30 arası uyanır, akşam yemeğini geç (20:30-21:30 " +
  "arası) yer, gece 02:30-03:30 arası uyur.",
  "Serbest/düzensiz çalışan tipi: gün gün değişen, kalıba uymayan yemek " +
  "saatleri var; geleneksel öğün saatlerini atlayıp ara sıra atıştırabilir, " +
  "uyku saati HİÇBİR ZAMAN 01:00'den önce olmaz, genelde 02:00-04:00 arası " +
  "değişken.",
  "Vardiyalı/alışılmadık saatler tipi: akşam ya da gece çalışır, ana " +
  "öğününü 15:00 veya 22:00 gibi sıra dışı bir saatte yer, uyku saati " +
  "HİÇBİR ZAMAN 01:00'den önce olmaz, iş bitimine göre 03:00-05:00 arası " +
  "da olabilir.",
];

function buildScheduleInstructions(interests: string[]): string {
  const chronotype = CHRONOTYPES[Math.floor(Math.random() * CHRONOTYPES.length)];
  const interestsNote = interests.length > 0
    ? `Karakterin ilgi alanları: ${interests.join(", ")}. Uygun düşen boş ` +
      `zaman/hafta sonu bloklarını bunlarla renklendir (ör. bir outdoor hobi ` +
      "varsa hafta sonu bloklarından biri o olsun, bir gaming/ev hobisi varsa " +
      "akşam boş zaman bloklarından biri o olsun) — ama HER blok değil, " +
      "sadece mantıklı düşenler; işle/uykuyla çelişen bir ilgi alanını o " +
      "bloğa zorlama. "
    : "";
  return (
    "Bu karakter için gerçekçi bir günlük rutin (hafta içi + hafta sonu) " +
    "üret. Kişiliğine ve mesleğine uygun, somut zaman blokları yaz — uyku " +
    "dahil GÜNÜN TAMAMINI boşluksuz kapla. Hafta sonu hafta içinden FARKLI " +
    "olmalı (çoğu meslek 7 gün çalışmaz). " + interestsNote +
    `UYANMA/YEMEK/UYKU SAATLERİNİ ŞU KALIBA GÖRE BELİRLE: ${chronotype} ` +
    "Bu kalıp karakterin gerçek mesleğiyle AÇIKÇA çelişmedikçe (ör. gece " +
    "vardiyasında çalışan biri sabahçı olamaz) uygula; çelişirse kalıbın " +
    "RUHUNU (ör. düzensiz/sıra dışı saatler) mesleğe uyarlayarak koru. " +
    "SERT KURAL: uyku bloğu (isSleep:true) HİÇBİR ZAMAN gece 01:00'den ÖNCE " +
    "başlayamaz — bu geç saatlere kadar sohbet edilen bir uygulama, hiçbir " +
    "karakter 01:00'den önce yatmaz, kalıpta ne yazarsa yazsın bu kuralı " +
    "asla ihlal etme. " +
    "`label` alanı KISA bir DURUM ifadesi olmalı — \"şu an ne yapıyor\" " +
    "sorusuna doğal bir cevap gibi oku (ör. \"Work\" değil \"At work\", " +
    "\"Dinner\" değil \"Having dinner\", \"Commute\" değil \"Commuting home\", " +
    "\"Sleep\" değil \"Asleep\"). " +
    "Her zaman karakterin kendi konuştuğu dilde yaz (bkz. sistem promptundaki " +
    "dil kuralı) — karakter Türkçe konuşuyorsa label/detail de Türkçe olsun, " +
    "asla otomatik İngilizceye geçme. " +
    "Karakterin UYUDUĞU blok(lar)da `isSleep` alanını `true` yap, diğer TÜM " +
    "bloklarda `false` yap — her gün için genelde tek bir uyku bloğu olur. " +
    "SADECE şu JSON şemasında cevap ver, başka hiçbir şey yazma (markdown " +
    "kod bloğu da yok):\n" +
    '{"weekday":[{"start":"HH:mm","end":"HH:mm","label":"kısa durum ' +
    'ifadesi","detail":"daha ayrıntılı açıklama","isSleep":false}],' +
    '"weekend":[...]}'
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
    const interests: string[] = Array.isArray(b.interests) ? b.interests : [];
    if (!characterId) return json({ error: "characterId required" }, 400);
    if (!systemPrompt) return json({ error: "systemPrompt required" }, 400);

    const resp = await fetch(XAI_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${XAI_API_KEY}` },
      body: JSON.stringify({
        model: MODEL,
        messages: [
          { role: "system", content: `${systemPrompt}\n\n${buildScheduleInstructions(interests)}` },
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

    const schedule = { weekday: parsed.weekday, weekend: parsed.weekend };

    // Üretilen rutini, VARSA kullanıcının bu karakterle konuşmasına KALICI yaz
    // (conversations.schedule, migration 009). Böylece her açılışta yeniden
    // ÜRETİLMEZ — hydrateConversations bunu geri okur, ensureGenerated atlar
    // (bkz. "her açılışta rutin üretimi → aşırı LLM isteği" sorunu). Konuşma
    // YOKSA OLUŞTURMA (hayalet sohbet olmasın); mesajlaşınca oluşan konuşmaya
    // bir sonraki üretimde yazılır. Best-effort: yazma başarısız olsa da rutini döndür.
    try {
      const { data: convo } = await db.from("conversations").select("id")
        .eq("user_id", uid).eq("character_id", characterId)
        .order("updated_at", { ascending: false }).limit(1);
      if (convo && convo[0]) {
        await db.from("conversations").update({ schedule }).eq("id", convo[0].id);
      }
    } catch (persistErr) {
      console.error("schedule persist err:", String(persistErr));
    }

    return json({ schedule });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
