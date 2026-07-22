// supabase/functions/civitai-whatif-test/index.ts
//
// TEMP TEST-ONLY, no auth — a small dispatcher for driving Civitai's
// orchestration API directly while researching/running the Scarlett LoRA
// training experiment. Not wired into any production flow. Delete once done.
//
// Request: { action: "proxy", method, path, query?, body? }
//   Forwards directly to https://orchestration.civitai.com<path>?<query>
//   with the real CIVITAI_API bearer token. `body` is JSON-serialized unless
//   `raw: true` + `bodyBase64` is given (for binary blob uploads).

const CIVITAI_API_TOKEN = Deno.env.get("CIVITAI_API") ?? "";
const BASE = "https://orchestration.civitai.com";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const b = await req.json();
    const path: string = b.path;
    const method: string = b.method ?? "GET";
    const query: string = b.query ?? "";
    const url = `${BASE}${path}${query ? `?${query}` : ""}`;

    let fetchBody: BodyInit | undefined;
    const headers: Record<string, string> = { Authorization: `Bearer ${CIVITAI_API_TOKEN}` };

    if (b.raw && b.bodyBase64) {
      fetchBody = Uint8Array.from(atob(b.bodyBase64), (c) => c.charCodeAt(0));
      headers["Content-Type"] = b.contentType ?? "application/octet-stream";
    } else if (b.body !== undefined) {
      fetchBody = JSON.stringify(b.body);
      headers["Content-Type"] = "application/json";
    }

    const r = await fetch(url, { method, headers, body: fetchBody });
    const text = await r.text();
    let parsed: unknown = text;
    try { parsed = JSON.parse(text); } catch { /* leave as raw text */ }
    return json({ status: r.status, body: parsed });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
