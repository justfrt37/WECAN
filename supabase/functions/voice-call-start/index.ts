// supabase/functions/voice-call-start/index.ts
//
// Starts a real-time voice call session. Finalizes any orphaned `active`
// session for this user first (crash recovery — see voice-call-end for the
// shared finalize logic), pre-checks balance, creates the new session row.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireVoiceEntitlement } from "../_shared/entitlements.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

const TOKENS_PER_SECOND = 3;
const MIN_START_BALANCE = 30; // ~10s of call time

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

// Charges for an orphaned/crashed session using its last checkpoint, marks
// it ended. Shared shape with voice-call-end's real finalize path, but kept
// as its own small copy here — voice-call-end additionally runs memory
// extraction, which an orphaned-session finalize should NOT do (no graceful
// end, no guarantee the transcript is coherent to summarize).
async function finalizeOrphaned(uid: string) {
  const { data: orphans } = await db
    .from("call_sessions")
    .select("id, last_checkpoint_seconds")
    .eq("user_id", uid)
    .eq("status", "active");
  if (!orphans || orphans.length === 0) return;
  for (const session of orphans) {
    const tokens = Math.round((session.last_checkpoint_seconds ?? 0) * TOKENS_PER_SECOND);
    if (tokens > 0) {
      await db.rpc("charge_tokens", { p_user_id: uid, p_amount: tokens, p_reason: "voice_call_orphaned" });
    }
    await db.from("call_sessions")
      .update({ status: "ended", ended_at: new Date().toISOString(), tokens_charged: tokens })
      .eq("id", session.id);
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);

    // Sesli arama Pro+ / Pro Max hakkı (bkz. _shared/entitlements.ts) — Pro'da
    // yok. Oturum açılmadan ve jeton düşülmeden ÖNCE kontrol edilir.
    const voiceGate = await requireVoiceEntitlement(db, uid);
    if (voiceGate) return json(voiceGate.body, voiceGate.status);

    const body = await req.json();
    const characterId: string = body.characterId;
    const conversationId: string | undefined = body.conversationId;
    if (!characterId) return json({ error: "characterId required" }, 400);

    await finalizeOrphaned(uid);

    const { data: balanceRow } = await db.from("token_balances").select("balance").eq("user_id", uid).maybeSingle();
    if ((balanceRow?.balance ?? 0) < MIN_START_BALANCE) {
      return json({ error: "insufficient_tokens" }, 402);
    }

    const { data: session, error } = await db.from("call_sessions").insert({
      user_id: uid,
      character_id: characterId,
      conversation_id: conversationId ?? null,
      status: "active",
    }).select("id").single();

    if (error || !session) return json({ error: String(error) }, 500);
    return json({ callSessionId: session.id });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
