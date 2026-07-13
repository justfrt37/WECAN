// supabase/functions/dev-list-voices/index.ts
//
// TEMPORARY / DEV-ONLY — backs the voice picker in the "DEV: Create Curated
// Character" panel. Proxies ElevenLabs' GET /v1/voices so the API key stays
// server-side; returns just what the picker needs (id/name/preview_url/
// category/labels). `preview_url` is a public ElevenLabs-hosted mp3 the
// client can hand straight to AVPlayer.
//
// Gated to the same two-uid dev allowlist as dev-upload-image/dev-create-character.
// DELETE this whole function once curated-character creation is retired.

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const ELEVENLABS_API_KEY = Deno.env.get("ELEVEN_LABS") ?? "";
const ELEVENLABS_VOICES_URL = "https://api.elevenlabs.io/v1/voices";

const DEV_UIDS = new Set([
  "81565166-be1e-48f6-a580-3f8b78e378e2",
  "9bd6b9c6-a498-42dd-a337-33a70100117f",
]);

function userIdFromJWT(authHeader: string | null): string | null {
  if (!authHeader?.startsWith("Bearer ")) return null;
  const token = authHeader.slice(7);
  const parts = token.split(".");
  if (parts.length < 2) return null;
  try {
    let b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    while (b64.length % 4) b64 += "=";
    return JSON.parse(atob(b64)).sub ?? null;
  } catch {
    return null;
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid || !DEV_UIDS.has(uid)) return json({ error: "forbidden" }, 403);

    const r = await fetch(ELEVENLABS_VOICES_URL, {
      headers: { "xi-api-key": ELEVENLABS_API_KEY },
    });
    if (!r.ok) return json({ error: `ElevenLabs ${r.status}: ${await r.text()}` }, 502);
    const d = await r.json();
    const voices = (d?.voices ?? []).map((v: Record<string, unknown>) => ({
      voice_id: v.voice_id,
      name: v.name,
      preview_url: v.preview_url,
      category: v.category,
      labels: v.labels,
    }));
    return json({ voices });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
