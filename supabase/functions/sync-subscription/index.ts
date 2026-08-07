// supabase/functions/sync-subscription/index.ts
//
// Bridges a real RevenueCat/StoreKit purchase into the server-side token
// economy. The client calls this right after a successful purchase/restore
// (and on launch). We NEVER trust the client's claim of a tier — instead we
// verify the entitlement against the RevenueCat REST API using the SECRET key
// (server-side only), then upsert the `subscriptions` row and drip that tier's
// weekly tokens. Shared verify/upsert logic lives in
// _shared/subscriptionSync.ts (also used by revenuecat-webhook for the push
// side of this same sync, e.g. renewals/cancellations that happen while the
// app isn't open).
//
// Required secret (Supabase → Edge Functions → Secrets):
//   REVENUECAT_SECRET_KEY = sk_...   (RevenueCat → API Keys → Secret key)
//
// Auth: Supabase user JWT. We ignore any appUserId in the body — the uid we
// sync is always the JWT's own `sub`, and that's also what the client logs
// RevenueCat's appUserID in as (Purchases.shared.logIn(uid)), so this uid IS
// the RevenueCat subscriber id too.

import { RC_SECRET, syncSubscriptionForUser } from "../_shared/subscriptionSync.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function userIdFromJWT(authHeader: string | null): string | null {
  if (!authHeader?.startsWith("Bearer ")) return null;
  const parts = authHeader.slice(7).split(".");
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
    if (!RC_SECRET) return json({ error: "server_misconfigured: REVENUECAT_SECRET_KEY missing" }, 500);

    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);

    const result = await syncSubscriptionForUser(uid);
    if ("error" in result) return json({ error: result.error }, result.status);
    return json(result);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
