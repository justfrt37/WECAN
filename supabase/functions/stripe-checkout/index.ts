// supabase/functions/stripe-checkout/index.ts
//
// Creates a Stripe Checkout Session for a subscription. Reuses one Stripe
// Customer per user (stripe_customers table) instead of creating a new one
// per session. Sets subscription_data.metadata.user_id so stripe-webhook
// can attribute every later event back to a user_id without a reverse
// Stripe-customer lookup.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@17?target=deno";
import { isDuration, isTier, priceIdFor } from "../_shared/stripe-prices.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });
const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { apiVersion: "2024-06-20" });

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

async function getOrCreateStripeCustomer(uid: string): Promise<string> {
  const { data: existing } = await db
    .from("stripe_customers")
    .select("stripe_customer_id")
    .eq("user_id", uid)
    .single();

  if (existing) return (existing as { stripe_customer_id: string }).stripe_customer_id;

  const { data: userData } = await db.auth.admin.getUserById(uid);
  const customer = await stripe.customers.create({
    email: userData.user?.email ?? undefined,
    metadata: { user_id: uid },
  });

  await db.from("stripe_customers").insert({ user_id: uid, stripe_customer_id: customer.id });
  return customer.id;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);

    const body = await req.json().catch(() => ({}));
    const tier: string | undefined = body.tier;
    const duration: string | undefined = body.duration;
    if (!tier || !isTier(tier) || !duration || !isDuration(duration)) {
      return json({ error: "invalid tier or duration" }, 400);
    }

    const customerId = await getOrCreateStripeCustomer(uid);
    const origin = req.headers.get("origin") ?? "https://plumm.app";

    const session = await stripe.checkout.sessions.create({
      mode: "subscription",
      customer: customerId,
      line_items: [{ price: priceIdFor(tier, duration), quantity: 1 }],
      subscription_data: { metadata: { user_id: uid } },
      success_url: `${origin}/profile?checkout=success`,
      cancel_url: `${origin}/profile?checkout=cancel`,
    });

    return json({ url: session.url });
  } catch (err) {
    return json({ error: err instanceof Error ? err.message : "unknown error" }, 500);
  }
});
