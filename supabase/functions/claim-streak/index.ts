// supabase/functions/claim-streak/index.ts
//
// Daily free-token streak grant. Eligibility is gated by the SERVER's own
// UTC clock (minimum elapsed wall-clock time since the last claim) — never
// trust a client-reported local date for the actual grant decision, only
// for cosmetic display (see design doc "Anti-abuse"). A user who fakes their
// device clock forward/back cannot claim more than once per real ~20h window.
//
// Also doubles as the "welcome grant" — MainTabView calls this once per app
// launch (see Swift StreakService/MainTabView), so a brand-new user's very
// first call here IS their day-1 streak claim, no separate mechanism needed.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

const BASE_GRANT = 10;
const MIN_HOURS_BETWEEN_CLAIMS = 20;

function multiplierForStreak(streak: number): number {
  if (streak <= 1) return 1;
  if (streak <= 4) return 2;
  if (streak <= 6) return 3;
  return 5; // day 7+
}

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
    if (!uid) return json({ error: "unauthorized" }, 401);

    const body = await req.json().catch(() => ({}));
    const clientLocalDate: string | undefined = typeof body.localDate === "string" ? body.localDate : undefined;

    const { data: state } = await db
      .from("streak_state")
      .select("current_streak, last_claim_at, last_claimed_local_date")
      .eq("user_id", uid)
      .maybeSingle();

    const now = new Date();
    if (state?.last_claim_at) {
      const hoursSince = (now.getTime() - new Date(state.last_claim_at).getTime()) / 3_600_000;
      if (hoursSince < MIN_HOURS_BETWEEN_CLAIMS) {
        return json({ granted: false, reason: "already_claimed_today" });
      }
    }

    // Streak continues only if the client's own local date advanced by
    // exactly one day since the last claim; anything else (first-ever claim,
    // a gap, or a suspicious multi-day jump) restarts at day 1.
    let newStreak = 1;
    if (state?.last_claimed_local_date && clientLocalDate) {
      const prev = new Date(state.last_claimed_local_date + "T00:00:00Z");
      const curr = new Date(clientLocalDate + "T00:00:00Z");
      const dayDiff = Math.round((curr.getTime() - prev.getTime()) / 86_400_000);
      if (dayDiff === 1) newStreak = (state.current_streak ?? 0) + 1;
    }

    const amount = BASE_GRANT * multiplierForStreak(newStreak);

    await db.from("streak_state").upsert({
      user_id: uid,
      current_streak: newStreak,
      last_claim_at: now.toISOString(),
      last_claimed_local_date: clientLocalDate ?? now.toISOString().slice(0, 10),
    });

    await db.rpc("grant_tokens", { p_user_id: uid, p_amount: amount, p_reason: "streak" });

    const { data: balanceRow } = await db
      .from("token_balances")
      .select("balance")
      .eq("user_id", uid)
      .single();

    return json({ granted: true, amount, newStreak, balance: balanceRow?.balance ?? amount });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
