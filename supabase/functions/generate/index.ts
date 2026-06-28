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

const XAI_API_KEY = Deno.env.get("XAI_API_KEY") ?? "";
const XAI_URL = "https://api.x.ai/v1/chat/completions";
const MODEL = "grok-4-1-fast-non-reasoning";

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
    const body = await req.json();
    const prompt: string = body.prompt ?? "";
    const maxTokens: number = body.maxTokens ?? 220;
    if (!prompt.trim()) return json({ error: "prompt required" }, 400);

    const resp = await fetch(XAI_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${XAI_API_KEY}`,
      },
      body: JSON.stringify({
        model: MODEL,
        messages: [{ role: "user", content: prompt }],
        temperature: 1.0,
        max_tokens: maxTokens,
      }),
    });
    if (!resp.ok) {
      const text = await resp.text();
      return json({ error: `LLM ${resp.status}: ${text}` }, 500);
    }
    const data = await resp.json();
    const text = data?.choices?.[0]?.message?.content ?? "";
    return json({ text });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
