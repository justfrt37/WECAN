// supabase/functions/dev-upload-image/index.ts
//
// TEMPORARY / DEV-ONLY — backs the Profile tab's "DEV: Create Curated
// Character" panel. Uploads ONE device photo (base64) to the shared public
// `characters` storage bucket and returns its public URL. Called once per
// picked photo (profile pic / gallery / in-chat) instead of batching, so a
// large multi-photo submission never hits one giant request payload.
//
// Gated to a hardcoded two-uid dev allowlist, uid taken ONLY from the JWT
// (never trusted from the request body) — same pattern as dev-token-tools.
// DELETE this whole function once curated-character creation is retired.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

// Kept in sync with aiGirlfriend/Services/DevAccess.swift's devUserIDs — the
// only two active dev users on this project (see project memory).
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

    const b = await req.json();
    const imageBase64: string = b.imageBase64 ?? "";
    // `kind` is purely for the storage path (helps eyeballing the bucket
    // contents later) — profile/gallery/chat don't need separate DB tables
    // for the file itself, only for how it's later referenced.
    const kind: string = ["profile", "gallery", "chat"].includes(b.kind) ? b.kind : "misc";
    if (!imageBase64) return json({ error: "imageBase64 required" }, 400);

    const bytes = Uint8Array.from(atob(imageBase64), (c) => c.charCodeAt(0));
    const path = `curated/${kind}/${crypto.randomUUID()}.png`;
    const { error } = await db.storage.from("characters").upload(path, bytes, {
      contentType: "image/png",
      upsert: false,
    });
    if (error) return json({ error: `Storage upload failed: ${error.message}` }, 500);

    const { data } = db.storage.from("characters").getPublicUrl(path);
    return json({ url: data.publicUrl });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
