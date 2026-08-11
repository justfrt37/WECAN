// Shared RevenueCat verification + subscriptions-table sync logic.
// Used by both sync-subscription (client-triggered, pull) and
// revenuecat-webhook (RC-triggered, push) so there's exactly one place that
// decides what "the truth" is: always a fresh call to RC's REST API with the
// secret key, never the client's or the webhook payload's own claims about
// tier — those are just triggers to go re-check.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
export const RC_SECRET = Deno.env.get("REVENUECAT_SECRET_KEY");

export const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

// Entitlement identifier → tier. Highest wins if several are active.
const TIER_PRIORITY = ["max", "pro_plus", "pro"];
const WEEKLY_TOKENS: Record<string, number> = { pro: 1000, pro_plus: 2500, max: 6000 };
// Entitlement dashboard'da yapılandırılmamış olabilir — o durumda aktif
// SUBSCRIPTION ürününü doğrudan tier'a eşle (entitlement'tan bağımsız).
const PRODUCT_TIER: Record<string, string> = {
  weekly_pro_normal: "pro", monthly_pro_default: "pro", yearly_pro_normal: "pro",
  weekly_pro_plus: "pro_plus", monthly_pro_plus: "pro_plus", yearly_pro_plus: "pro_plus",
  weekly_pro_max: "max", monthly_pro_max: "max", yearly_pro_max: "max",
};
// Ürüne özel token miktarı (dönem başına).
const PRODUCT_TOKENS: Record<string, number> = {
  weekly_pro_normal: 250, monthly_pro_default: 1000, yearly_pro_normal: 12000,
  weekly_pro_plus: 500, monthly_pro_plus: 2000, yearly_pro_plus: 25000,
  weekly_pro_max: 750, monthly_pro_max: 3000, yearly_pro_max: 35000,
};

export async function currentBalance(uid: string): Promise<number> {
  const { data } = await db.from("token_balances").select("balance").eq("user_id", uid).maybeSingle();
  return data?.balance ?? 0;
}

export type SyncResult =
  | { tier: "none"; balance: number; debug: unknown }
  | { tier: string; balance: number; granted: boolean; debug: unknown }
  | { error: string; status: number };

// `uid` here MUST be a Supabase user id AND RevenueCat's app_user_id for that
// subscriber (PurchaseService.configure()/purchase()/restore() call
// Purchases.shared.logIn(uid) client-side precisely so these two are always
// the same string — no separate mapping table needed).
export async function syncSubscriptionForUser(uid: string): Promise<SyncResult> {
  if (!RC_SECRET) return { error: "server_misconfigured: REVENUECAT_SECRET_KEY missing", status: 500 };

  const rcResp = await fetch(
    `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(uid)}`,
    { headers: { Authorization: `Bearer ${RC_SECRET}`, "Content-Type": "application/json" } },
  );
  if (!rcResp.ok) return { error: `revenuecat_error_${rcResp.status}`, status: 502 };
  const rc = await rcResp.json();
  const entitlements = rc?.subscriber?.entitlements ?? {};
  const subs = rc?.subscriber?.subscriptions ?? {};
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

  for (const t of TIER_PRIORITY) {
    const e = entitlements[t];
    if (!e) continue;
    const active = e.expires_date == null || Date.parse(e.expires_date) > now;
    if (active) { activeTier = t; ent = e; activeProductId = e.product_identifier ?? null; break; }
  }

  if (!activeTier) {
    let bestPriority = Infinity;
    for (const [productId, s] of Object.entries(subs)) {
      const sub = s as { purchase_date?: string; expires_date?: string | null };
      const active = sub.expires_date == null || Date.parse(sub.expires_date) > now;
      const mapped = PRODUCT_TIER[productId];
      if (!active || !mapped) continue;
      const priority = TIER_PRIORITY.indexOf(mapped);
      if (priority !== -1 && priority < bestPriority) {
        bestPriority = priority;
        activeTier = mapped;
        ent = sub;
        activeProductId = productId;
      }
    }
  }

  if (!activeTier || !ent) {
    await db.from("subscriptions").delete().eq("user_id", uid);
    return { tier: "none", balance: await currentBalance(uid), debug };
  }

  const periodStart = ent.purchase_date ?? new Date().toISOString();
  const periodEnd = ent.expires_date ?? new Date(now + 365 * 86_400_000).toISOString();

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
    const amount = (activeProductId && PRODUCT_TOKENS[activeProductId]) ?? WEEKLY_TOKENS[activeTier];
    await db.rpc("grant_tokens", {
      p_user_id: uid,
      p_amount: amount,
      p_reason: "subscription_grant",
    });
  }

  return { tier: activeTier, balance: await currentBalance(uid), granted: isNewPeriod, debug };
}
