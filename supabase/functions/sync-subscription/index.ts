// supabase/functions/sync-subscription/index.ts
//
// Bridges a real RevenueCat/StoreKit purchase into the server-side token
// economy. The client calls this right after a successful purchase/restore
// (and on launch). We NEVER trust the client's claim of a tier — instead we
// verify the entitlement against the RevenueCat REST API using the SECRET key
// (server-side only), then upsert the `subscriptions` row and drip that tier's
// weekly tokens.
//
// Replaces the dev-only `dev-token-tools` stand-in for the subscribe flow.
//
// Required secret (Supabase → Edge Functions → Secrets):
//   REVENUECAT_SECRET_KEY = sk_...   (RevenueCat → API Keys → Secret key)
//
// Body: { "appUserId": "<Purchases.shared.appUserID>" }
// Auth: Supabase user JWT (the uid we credit is taken from the JWT, never the body).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RC_SECRET = Deno.env.get("REVENUECAT_SECRET_KEY");
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

// Entitlement identifier → tier. Highest wins if several are active.
const TIER_PRIORITY = ["max", "pro_plus", "pro"];
const WEEKLY_TOKENS: Record<string, number> = { pro: 1000, pro_plus: 2500, max: 6000 };
// Entitlement dashboard'da yapılandırılmamış olabilir — o durumda aktif
// SUBSCRIPTION ürününü doğrudan tier'a eşle (entitlement'tan bağımsız).
const PRODUCT_TIER: Record<string, string> = {
  weekly_pro: "pro",
  yearly_pro_2: "pro",
};
// Ürüne özel token miktarı (dönem başına): haftalık 100, yıllık 1000.
const PRODUCT_TOKENS: Record<string, number> = {
  weekly_pro: 100,
  yearly_pro_2: 1000,
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

async function currentBalance(uid: string): Promise<number> {
  const { data } = await db.from("token_balances").select("balance").eq("user_id", uid).maybeSingle();
  return data?.balance ?? 0;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    if (!RC_SECRET) return json({ error: "server_misconfigured: REVENUECAT_SECRET_KEY missing" }, 500);

    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);

    const body = await req.json().catch(() => ({}));
    const appUserId: string | undefined = body.appUserId;
    if (!appUserId) return json({ error: "missing_app_user_id" }, 400);

    // 1) Verify with RevenueCat (server-side, secret key).
    const rcResp = await fetch(
      `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(appUserId)}`,
      { headers: { Authorization: `Bearer ${RC_SECRET}`, "Content-Type": "application/json" } },
    );
    if (!rcResp.ok) return json({ error: `revenuecat_error_${rcResp.status}` }, 502);
    const rc = await rcResp.json();
    const entitlements = rc?.subscriber?.entitlements ?? {};
    const subs = rc?.subscriber?.subscriptions ?? {};
    // Teşhis: RC'nin bu kullanıcı için gerçekte ne bildiğini gör. `firstSeen`
    // "şimdi" ise subscriber bu GET ile yeni oluşmuştur → secret key YANLIŞ
    // PROJEDEN (satın alma başka projeye gitmiş) demektir.
    const debug = {
      entitlementKeys: Object.keys(entitlements),
      subscriptionKeys: Object.keys(subs),
      firstSeen: rc?.subscriber?.first_seen ?? null,
      originalAppUserId: rc?.subscriber?.original_app_user_id ?? null,
    };

    const now = Date.now();
    let activeTier: string | null = null;
    let activeProductId: string | null = null;
    let ent: { purchase_date?: string; expires_date?: string | null; product_identifier?: string } | null = null;

    // 2a) Önce entitlement (yapılandırılmışsa) — en yüksek aktif olan.
    for (const t of TIER_PRIORITY) {
      const e = entitlements[t];
      if (!e) continue;
      const active = e.expires_date == null || Date.parse(e.expires_date) > now;
      if (active) { activeTier = t; ent = e; activeProductId = e.product_identifier ?? null; break; }
    }

    // 2b) Entitlement yoksa aktif SUBSCRIPTION ürününden tier çıkar.
    if (!activeTier) {
      for (const [productId, s] of Object.entries(subs)) {
        const sub = s as { purchase_date?: string; expires_date?: string | null };
        const active = sub.expires_date == null || Date.parse(sub.expires_date) > now;
        const mapped = PRODUCT_TIER[productId];
        if (active && mapped) { activeTier = mapped; ent = sub; activeProductId = productId; break; }
      }
    }

    // 3) No active entitlement → clear any stale server subscription.
    if (!activeTier || !ent) {
      await db.from("subscriptions").delete().eq("user_id", uid);
      return json({ tier: "none", balance: await currentBalance(uid), debug });
    }

    const periodStart = ent.purchase_date ?? new Date().toISOString();
    const periodEnd = ent.expires_date ?? new Date(now + 365 * 86_400_000).toISOString();

    // 4) Idempotency: only drip weekly tokens when this is a NEW period
    //    (new purchase/renewal). Repeated syncs within the same period just
    //    keep the row fresh and DON'T re-grant (prevents token farming).
    const { data: existing } = await db
      .from("subscriptions")
      .select("current_period_start")
      .eq("user_id", uid)
      .maybeSingle();
    const isNewPeriod = existing?.current_period_start !== periodStart;

    await db.from("subscriptions").upsert({
      user_id: uid,
      tier: activeTier,
      current_period_start: periodStart,
      current_period_end: periodEnd,
      updated_at: new Date().toISOString(),
    });

    if (isNewPeriod) {
      // Ürüne özel miktar (haftalık 100 / yıllık 1000); ürün bilinmiyorsa
      // tier'ın varsayılan haftalık miktarına düş.
      const amount = (activeProductId && PRODUCT_TOKENS[activeProductId]) ?? WEEKLY_TOKENS[activeTier];
      await db.rpc("grant_tokens", {
        p_user_id: uid,
        p_amount: amount,
        p_reason: "subscription_grant",
      });
    }

    return json({ tier: activeTier, balance: await currentBalance(uid), granted: isNewPeriod, debug });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
