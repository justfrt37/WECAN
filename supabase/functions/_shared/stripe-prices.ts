// supabase/functions/_shared/stripe-prices.ts
//
// Bidirectional mapping between (tier, duration) and Stripe Price IDs.
// Price IDs live in env vars (set via `supabase secrets set`), never
// hardcoded -- they differ between Stripe test mode and live mode.

export type Tier = "pro" | "pro_plus" | "max";
export type Duration = "weekly" | "annual";

const ENV_VAR_NAMES: Record<Tier, Record<Duration, string>> = {
  pro: { weekly: "STRIPE_PRICE_PRO_WEEKLY", annual: "STRIPE_PRICE_PRO_ANNUAL" },
  pro_plus: { weekly: "STRIPE_PRICE_PRO_PLUS_WEEKLY", annual: "STRIPE_PRICE_PRO_PLUS_ANNUAL" },
  max: { weekly: "STRIPE_PRICE_MAX_WEEKLY", annual: "STRIPE_PRICE_MAX_ANNUAL" },
};

export function priceIdFor(tier: Tier, duration: Duration): string {
  const envVar = ENV_VAR_NAMES[tier][duration];
  const priceId = Deno.env.get(envVar);
  if (!priceId) throw new Error(`Missing env var ${envVar}`);
  return priceId;
}

export function tierAndDurationForPrice(priceId: string): { tier: Tier; duration: Duration } | null {
  for (const tier of Object.keys(ENV_VAR_NAMES) as Tier[]) {
    for (const duration of Object.keys(ENV_VAR_NAMES[tier]) as Duration[]) {
      if (Deno.env.get(ENV_VAR_NAMES[tier][duration]) === priceId) {
        return { tier, duration };
      }
    }
  }
  return null;
}

export function isTier(value: string): value is Tier {
  return value === "pro" || value === "pro_plus" || value === "max";
}

export function isDuration(value: string): value is Duration {
  return value === "weekly" || value === "annual";
}
