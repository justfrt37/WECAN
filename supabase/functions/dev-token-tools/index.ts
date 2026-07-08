// supabase/functions/dev-token-tools/index.ts
//
// TEMPORARY — backs the Profile tab's dev test panel (+1000/-1000 tokens,
// simulate subscribing to Pro/Pro+/Max/off). Only ever touches the CALLING
// user's own uid (extracted server-side from their JWT, never accepted as a
// client parameter) — so this can't be used to touch another user's balance
// or subscription no matter what the request body claims.
//
// DELETE this whole function once real RevenueCat/StoreKit purchases are
// wired up (see docs/superpowers/specs/2026-07-08-token-system-design.md
// "Dependencies") — this is a stand-in for that flow during development.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

const WEEKLY_TOKENS: Record<string, number> = {
  pro: 1000,
  pro_plus: 2500,
  max: 6000,
};

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

async function currentBalance(uid: string): Promise<number> {
  const { data } = await db.from("token_balances").select("balance").eq("user_id", uid).maybeSingle();
  return data?.balance ?? 0;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);

    const body = await req.json();
    const action: string = body.action;

    if (action === "add_tokens") {
      const { data: balance } = await db.rpc("debug_adjust_balance", { p_user_id: uid, p_delta: 1000 });
      return json({ balance });
    }

    if (action === "remove_tokens") {
      const { data: balance } = await db.rpc("debug_adjust_balance", { p_user_id: uid, p_delta: -1000 });
      return json({ balance });
    }

    if (action === "set_tier") {
      const tier: string = body.tier;
      if (tier === "none") {
        await db.from("subscriptions").delete().eq("user_id", uid);
        const balance = await currentBalance(uid);
        return json({ balance, tier: "none" });
      }
      if (!WEEKLY_TOKENS[tier]) return json({ error: "invalid_tier" }, 400);

      const now = new Date();
      const periodEnd = new Date(now.getTime() + 7 * 86_400_000);
      // "Mimics a subscription being bought for the first time" — a real
      // purchase resets the period AND drips that tier's weekly tokens, so
      // this does both, not just a flag flip.
      await db.from("subscriptions").upsert({
        user_id: uid,
        tier,
        current_period_start: now.toISOString(),
        current_period_end: periodEnd.toISOString(),
        updated_at: now.toISOString(),
      });
      await db.rpc("grant_tokens", { p_user_id: uid, p_amount: WEEKLY_TOKENS[tier], p_reason: "subscription_grant" });
      const balance = await currentBalance(uid);
      return json({ balance, tier });
    }

    return json({ error: "unknown_action" }, 400);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
