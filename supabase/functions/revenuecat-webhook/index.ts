// supabase/functions/revenuecat-webhook/index.ts
//
// Server-pushed half of the subscription sync (see also sync-subscription,
// which is the client-triggered pull half — both call the same
// _shared/subscriptionSync.ts). Without this, the `subscriptions` table only
// ever updated when the app itself called sync-subscription — so a renewal,
// cancellation, refund, billing issue, or chargeback that happens while the
// user hasn't opened the app just sat unreflected server-side until next
// launch. This closes that gap: RevenueCat calls us directly on every
// subscriber event.
//
// We don't trust the event payload's own tier/expiration claims — we just use
// it as a trigger to re-verify that subscriber against RC's REST API (the
// same secret-key call sync-subscription makes), so this can't be spoofed by
// a crafted event body even if the auth check below were somehow bypassed.
//
// Setup:
//   1. Supabase secret REVENUECAT_WEBHOOK_AUTH = <random long string>
//      (`npx supabase secrets set REVENUECAT_WEBHOOK_AUTH=... --project-ref ohpvhgwjmrfjclnumgnm`)
//   2. RevenueCat dashboard → Project → Integrations → Webhooks → Add:
//        URL: https://<project-ref>.supabase.co/functions/v1/revenuecat-webhook
//        Authorization header value: the same REVENUECAT_WEBHOOK_AUTH string
//   3. REVENUECAT_SECRET_KEY must already be set (shared with sync-subscription).
//
// Client-side prerequisite: Purchases.shared.logIn(supabaseUserId) — done in
// PurchaseService — so RC's app_user_id IS the Supabase uid, with no separate
// mapping table needed here.

import { syncSubscriptionForUser } from "../_shared/subscriptionSync.ts";

const WEBHOOK_AUTH = Deno.env.get("REVENUECAT_WEBHOOK_AUTH");

Deno.serve(async (req: Request) => {
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  if (!WEBHOOK_AUTH) return json({ error: "server_misconfigured: REVENUECAT_WEBHOOK_AUTH missing" }, 500);
  const auth = req.headers.get("Authorization");
  if (auth !== `Bearer ${WEBHOOK_AUTH}` && auth !== WEBHOOK_AUTH) {
    return json({ error: "unauthorized" }, 401);
  }

  const body = await req.json().catch(() => null);
  const event = body?.event;
  if (!event) return json({ error: "missing_event" }, 400);

  // TRANSFER events move an entitlement between two app_user_ids instead of
  // reporting one subject — resync both sides. Every other event type
  // (INITIAL_PURCHASE, RENEWAL, CANCELLATION, EXPIRATION, UNCANCELLATION,
  // PRODUCT_CHANGE, BILLING_ISSUE, SUBSCRIPTION_PAUSED, ...) reports a single
  // app_user_id, and re-verifying that subscriber handles all of them
  // uniformly — we don't need to special-case what changed, just re-check
  // current truth.
  const affectedUids: string[] = event.type === "TRANSFER"
    ? [...(event.transferred_from ?? []), ...(event.transferred_to ?? [])]
    : [event.app_user_id].filter(Boolean);

  if (affectedUids.length === 0) return json({ ok: true, skipped: "no_app_user_id" });

  const results: Record<string, unknown> = {};
  for (const uid of affectedUids) {
    results[uid] = await syncSubscriptionForUser(uid);
  }

  return json({ ok: true, type: event.type, results });
});
