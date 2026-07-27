// supabase/functions/voice-call-checkpoint/index.ts
//
// Called every ~5s by the client during an active call. Records the elapsed
// time as a crash-recovery marker (no charge here — billing settles once in
// voice-call-end) and checks whether the projected cost would exceed the
// user's balance, so the client can end the call before going negative.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

const TOKENS_PER_SECOND = 3;

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

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);

    const body = await req.json();
    const callSessionId: string = body.callSessionId;
    const elapsedSeconds: number = Number(body.elapsedSeconds) || 0;
    if (!callSessionId) return json({ error: "callSessionId required" }, 400);

    const { data: session } = await db.from("call_sessions")
      .select("id, user_id, status").eq("id", callSessionId).maybeSingle();
    if (!session || session.user_id !== uid || session.status !== "active") {
      return json({ ok: false }, 400);
    }

    await db.from("call_sessions")
      .update({ last_checkpoint_seconds: elapsedSeconds })
      .eq("id", callSessionId);

    const { data: balanceRow } = await db.from("token_balances").select("balance").eq("user_id", uid).maybeSingle();
    const projectedCost = elapsedSeconds * TOKENS_PER_SECOND;
    if (projectedCost > (balanceRow?.balance ?? 0)) {
      return json({ ok: false });
    }
    return json({ ok: true });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
