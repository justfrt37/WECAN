// supabase/functions/xai-bootstrap-test/index.ts
//
// TEMP TEST-ONLY, no auth — bootstraps varied-pose seed images for LoRA
// training using the SAME mechanism already proven in production
// chat-image/index.ts (editsWithBaseline: xAI Grok Imagine /v1/images/edits,
// image-to-image with a baseline reference). Chosen over Civitai's Flux1
// Kontext dev after two real Kontext attempts on Scarlett both drifted the
// face noticeably (see civitai_test_images/scarlett_lora_bootstrap/01 and
// 02 vs the real reference) — falling back to the mechanism the live app
// actually uses successfully every day instead of the untested Civitai path.
//
// Request: { prompt, baselineImageUrl }
// Response: { url } (uploaded to Supabase Storage characters/lora-bootstrap/)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const XAI_API_KEY = Deno.env.get("XAI_API_KEY") ?? "";
const XAI_IMAGE_EDITS_URL = "https://api.x.ai/v1/images/edits";
const IMAGE_MODEL = "grok-imagine-image";
const IMAGE_RESOLUTION = "2k";
const IMAGE_ASPECT_RATIO = "9:16";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

async function bytesFromImageResponse(r: Response): Promise<Uint8Array> {
  if (!r.ok) throw new Error(`Image gen ${r.status}: ${await r.text()}`);
  const d = await r.json();
  const item = d?.data?.[0];
  if (item?.b64_json) return Uint8Array.from(atob(item.b64_json), (c: string) => c.charCodeAt(0));
  if (item?.url) {
    const imgResp = await fetch(item.url);
    if (!imgResp.ok) throw new Error(`Image download ${imgResp.status}`);
    return new Uint8Array(await imgResp.arrayBuffer());
  }
  throw new Error("No image data in xAI response");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const b = await req.json();
    const prompt: string = b.prompt;
    const baselineImageUrl: string = b.baselineImageUrl;
    if (!prompt || !baselineImageUrl) return json({ error: "prompt and baselineImageUrl required" }, 400);

    const r = await fetch(XAI_IMAGE_EDITS_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${XAI_API_KEY}` },
      body: JSON.stringify({
        model: IMAGE_MODEL,
        prompt,
        image: { url: baselineImageUrl, type: "image_url" },
        aspect_ratio: IMAGE_ASPECT_RATIO,
        resolution: IMAGE_RESOLUTION,
      }),
    });
    const bytes = await bytesFromImageResponse(r);

    const path = `lora-bootstrap/${crypto.randomUUID()}.png`;
    const { error } = await db.storage.from("characters").upload(path, bytes, { contentType: "image/png", upsert: false });
    if (error) throw new Error(`Storage upload failed: ${error.message}`);
    const { data } = db.storage.from("characters").getPublicUrl(path);
    return json({ url: data.publicUrl });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
