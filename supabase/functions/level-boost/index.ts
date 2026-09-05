// supabase/functions/level-boost/index.ts
//
// "Boost" button on RelationshipLevelsView — instantly gain ONE relationship
// level (never more than one per call, matches "additional level" phrasing).
//
// Tier rules (bkz. kullanıcı talebi 2026-09-05):
//   • none  → 403 subscription_required (client opens the paywall, never calls)
//   • max   → free, no token charge
//   • pro / pro_plus → costs tokens (costForTargetLevel), 402 if short
//
//   İstek:  { characterId }
//   Cevap:  { level, levelProgress, tokenBalance }  veya  { error }

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { activeTier } from "../_shared/entitlements.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const db = createClient(SUPABASE_URL, SERVICE_ROLE, {
  auth: { persistSession: false },
});

const MAX_LEVEL = 10;

// Fiyat, hedef seviyeye göre (bkz. kullanıcı talebi 2026-08-31): 5'e kadar
// (2-5) 50, 6-8 100, 9-10 200.
function costForTargetLevel(targetLevel: number): number {
  if (targetLevel <= 5) return 50;
  if (targetLevel <= 8) return 100;
  return 200;
}

function userIdFromJWT(authHeader: string | null): string | null {
  if (!authHeader) return null;
  const jwt = authHeader.replace("Bearer ", "").trim();
  const parts = jwt.split(".");
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
    if (!uid) return json({ error: "unauthorized" }, 401);

    const b = await req.json();
    const characterId: string = b.characterId;
    if (!characterId) return json({ error: "characterId required" }, 400);

    const { data: convo } = await db
      .from("conversations")
      .select("id, relationship_level")
      .eq("user_id", uid)
      .eq("character_id", characterId)
      .order("updated_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (!convo) return json({ error: "conversation_not_found" }, 404);

    const currentLevel: number = convo.relationship_level ?? 1;
    if (currentLevel >= MAX_LEVEL) return json({ error: "already_max_level" }, 400);

    const tier = await activeTier(db, uid);
    if (tier === "none") {
      return json({ error: "subscription_required", required_tier: "pro" }, 403);
    }

    const targetLevel = currentLevel + 1;

    // max: bedava. pro / pro_plus: token öder.
    if (tier !== "max") {
      const cost = costForTargetLevel(targetLevel);
      const { data: charged } = await db.rpc("charge_tokens", {
        p_user_id: uid,
        p_amount: cost,
        p_reason: "level_boost",
      });
      if (!charged) return json({ error: "insufficient_tokens" }, 402);
    }

    await db.from("conversations")
      .update({ relationship_level: targetLevel, level_progress: 0, updated_at: new Date().toISOString() })
      .eq("id", convo.id);

    const { data: balanceRow } = await db.from("token_balances").select("balance").eq("user_id", uid).maybeSingle();

    return json({ level: targetLevel, levelProgress: 0, tokenBalance: balanceRow?.balance ?? 0 });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
