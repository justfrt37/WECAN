// supabase/functions/tts/index.ts
//
// Metni kaliteli sese çevirir (OpenAI TTS). Kızın sesli cevapları için.
//   İstek:  { text: string, voice?: string }
//   Cevap:  audio/mpeg (mp3 bytes)
//
// Gerekli secret: OPENAI_API_KEY  (yoksa 500 döner → istemci cihaz içi sese düşer)
// Kurulum: supabase secrets set OPENAI_API_KEY=sk-...

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY") ?? "";

// JWT doğrulaması YOKTU — anon key'i bilen HERKES (uygulama bundle'ında
// zaten public) sınırsız metin gönderip OpenAI TTS kredisini tüketebiliyordu
// (bkz. generate/index.ts'deki aynı bug). Diğer tüm fonksiyonlar gibi gerçek
// oturum JWT'si zorunlu — client (TTSService.swift) zaten accessToken
// varsa onu gönderiyordu, sadece sunucu hiç kontrol etmiyordu.
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

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) {
      return new Response(JSON.stringify({ error: "unauthorized" }), {
        status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (!OPENAI_API_KEY) {
      return new Response(JSON.stringify({ error: "no_tts_key" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    const body = await req.json();
    const text: string = (body.text ?? "").toString().slice(0, 800);
    const voice: string = body.voice ?? "shimmer";
    if (!text.trim()) {
      return new Response(JSON.stringify({ error: "text required" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const resp = await fetch("https://api.openai.com/v1/audio/speech", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${OPENAI_API_KEY}` },
      body: JSON.stringify({ model: "gpt-4o-mini-tts", voice, input: text, response_format: "mp3" }),
    });
    if (!resp.ok) {
      const t = await resp.text();
      return new Response(JSON.stringify({ error: `tts ${resp.status}: ${t}` }), {
        status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    const audio = await resp.arrayBuffer();
    return new Response(audio, {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "audio/mpeg" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
