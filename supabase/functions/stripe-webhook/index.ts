// supabase/functions/stripe-webhook/index.ts
//
// Public endpoint (Stripe calls this directly -- no JWT, verified via
// Stripe's signature header instead). Keeps the shared `subscriptions`
// table in sync with Stripe subscription state.
//
// customer.subscription.deleted is the ONLY row-delete path. Stripe fires
// `updated` immediately when a user cancels (cancel_at_period_end: true)
// but the subscription stays active until the period actually ends, and
// only then fires `deleted`. So relying solely on `deleted` for removal
// means a canceled-but-still-in-period user keeps their tier for free,
// with no extra `status` column needed -- matches the existing
// no-row-means-free convention from the token-system design.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@17?target=deno";
import { tierAndDurationForPrice } from "../_shared/stripe-prices.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });
const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { apiVersion: "2024-06-20" });
const WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;

async function upsertSubscription(sub: Stripe.Subscription) {
  const userId = sub.metadata.user_id;
  if (!userId) return; // not one of ours (shouldn't happen -- checkout always sets this)

  const priceId = sub.items.data[0]?.price.id;
  const mapped = priceId ? tierAndDurationForPrice(priceId) : null;
  if (!mapped) return; // unknown price, nothing we can map to a tier

  await db.from("subscriptions").upsert({
    user_id: userId,
    tier: mapped.tier,
    current_period_start: new Date(sub.current_period_start * 1000).toISOString(),
    current_period_end: new Date(sub.current_period_end * 1000).toISOString(),
    updated_at: new Date().toISOString(),
  });
}

async function deleteSubscription(sub: Stripe.Subscription) {
  const userId = sub.metadata.user_id;
  if (!userId) return;
  await db.from("subscriptions").delete().eq("user_id", userId);
}

Deno.serve(async (req: Request) => {
  const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

  const signature = req.headers.get("stripe-signature");
  if (!signature) return json({ error: "missing signature" }, 400);

  const rawBody = await req.text();
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(rawBody, signature, WEBHOOK_SECRET);
  } catch (err) {
    return json({ error: `signature verification failed: ${err instanceof Error ? err.message : err}` }, 400);
  }

  switch (event.type) {
    case "customer.subscription.created":
    case "customer.subscription.updated":
      await upsertSubscription(event.data.object as Stripe.Subscription);
      break;
    case "customer.subscription.deleted":
      await deleteSubscription(event.data.object as Stripe.Subscription);
      break;
    default:
      return json({ ignored: true });
  }

  return json({ received: true });
});
