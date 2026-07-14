// supabase/functions/stripe-portal/index.ts
//
// Creates a Stripe Billing Portal session so a subscribed user can
// manage/cancel/upgrade without any custom UI. Requires an existing
// stripe_customers row -- only reachable from the client when
// fetchSubscriptionStatus already returned a paid tier.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@17?target=deno";

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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);

    const { data } = await db.from("stripe_customers").select("stripe_customer_id").eq("user_id", uid).single();
    if (!data) return json({ error: "no_customer" }, 404);

    const origin = req.headers.get("origin") ?? "https://plumm.app";
    const portalSession = await stripe.billingPortal.sessions.create({
      customer: (data as { stripe_customer_id: string }).stripe_customer_id,
      return_url: `${origin}/profile`,
    });

    return json({ url: portalSession.url });
  } catch (err) {
    return json({ error: err instanceof Error ? err.message : "unknown error" }, 500);
  }
});
