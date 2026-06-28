// supabase/functions/civitai-image/index.ts
//
// Civitai üzerinden görsel üretir (NSFW serbest checkpoint'ler).
//   İstek: { prompt, negativePrompt?, style?: "realistic"|"anime", width?, height? }
//   Cevap: { url }  (üretilen görselin Civitai blob URL'i)
//
// Gerekli secret: CIVITAI_API_TOKEN  (civitai.com > Account > API Keys) + hesapta Buzz.
// Yoksa 500 döner → istemci havuz görseline düşer.

import { Civitai, Scheduler } from "https://esm.sh/civitai@0.1.15";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const TOKEN = Deno.env.get("CIVITAI_API_TOKEN") ?? "";

// Kategoriye göre NSFW checkpoint (AIR).
const MODELS: Record<string, string> = {
  realistic: "urn:air:sdxl:checkpoint:civitai:312530@2840768", // CyberRealistic XL v10
  anime: "urn:air:sdxl:checkpoint:civitai:257749@290640",      // Pony Diffusion V6 XL
};

const DEFAULT_NEG =
  "child, minor, underage, teen, deformed, lowres, bad anatomy, bad hands, " +
  "extra fingers, watermark, text, blurry, ugly";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    if (!TOKEN) return json({ error: "no_civitai_key" }, 500);
    const b = await req.json();
    const prompt: string = (b.prompt ?? "").toString();
    if (!prompt.trim()) return json({ error: "prompt required" }, 400);
    const style: string = b.style === "anime" ? "anime" : "realistic";
    const model = MODELS[style];

    const civitai = new Civitai({ auth: TOKEN });
    const input = {
      model,
      params: {
        prompt,
        negativePrompt: (b.negativePrompt ?? DEFAULT_NEG).toString(),
        scheduler: Scheduler.EULER_A,
        steps: 28,
        cfgScale: 5,
        width: b.width ?? 832,
        height: b.height ?? 1216,
        clipSkip: 2,
      },
      quantity: 1,
    };

    // wait=true → iş bitene kadar bekler ve sonucu döner.
    const resp = await civitai.image.fromText(input as any, true);
    const url =
      resp?.jobs?.[0]?.result?.blobUrl ??
      resp?.jobs?.[0]?.result?.[0]?.blobUrl ??
      null;
    if (!url) return json({ error: "no_image", raw: resp }, 500);
    return json({ url });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
