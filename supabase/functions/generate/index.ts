// supabase/functions/generate/index.ts
//
// Genel amaçlı kısa metin üretimi (xAI Grok). Karakter yaratmada
// "AI ile senaryo öner" gibi yerlerde kullanılır. DB'ye dokunmaz.
//
//   İstek:  { prompt: string, maxTokens?: number }
//   Cevap:  { text: string }

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

import { callLLM } from "../_shared/llm.ts";

// Bu fonksiyonun JWT doğrulaması YOKTU — anon key'i bilen HERKES (uygulama
// bundle'ında zaten public) sınırsız serbest-metin prompt gönderip xAI
// kredisini tüketebiliyordu. Diğer TÜM fonksiyonlar gibi gerçek oturum JWT'si
// zorunlu tutuluyor (bkz. GenerateService.swift — client zaten accessToken
// varsa onu gönderiyordu, sadece sunucu tarafı hiç kontrol etmiyordu).
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
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);

    const body = await req.json();
    const prompt: string = body.prompt ?? "";
    const maxTokens: number = body.maxTokens ?? 220;
    if (!prompt.trim()) return json({ error: "prompt required" }, 400);

    const text = await callLLM(
      [{ role: "user", content: prompt }],
      { maxTokens, temperature: 1.0 },
    );
    return json({ text });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
