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

    // Atomik check+grant — bkz. migration atomic_claim_streak. Eskiden
    // eligibility-check ile upsert+grant arasında satır kilidi yoktu: iki eş
    // zamanlı çağrı (çift-launch/retry) ikisi de check'i geçip çift streak
    // ödülü verebiliyordu. Artık tamamı tek `for update` kilitli fonksiyonda.
    const { data, error } = await db.rpc("claim_streak", {
      p_user_id: uid,
      p_client_local_date: clientLocalDate ?? null,
    });
    if (error) return json({ error: error.message }, 500);
    const row = data?.[0];
    if (!row) return json({ error: "claim_streak returned no row" }, 500);

    return json({
      granted: row.granted,
      reason: row.reason ?? undefined,
      amount: row.amount,
      newStreak: row.new_streak,
      balance: row.balance,
    });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
