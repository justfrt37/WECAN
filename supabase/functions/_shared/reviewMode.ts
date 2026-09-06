// supabase/functions/_shared/reviewMode.ts
//
// App Store "review mode" — server-authoritative.
//
// The single source of truth is `app_config.kokomombo` (boolean). When it is
// true the app must behave as a strictly wholesome, platonic companion:
// characters come from `characters_review`, chat/voice use REVIEW_DIRECTIVE,
// and generated photos are forced fully-clothed.
//
// The client also passes a `reviewMode` flag on requests, but an older shipped
// binary may not — and a binary already in App Review cannot be updated. So
// every entry point that gates on review mode reads this helper and treats the
// DB value as authoritative (client flag is only ever an OR on top, never a
// way to turn review mode OFF).
//
// Cached in-memory with a short TTL so toggling the flag propagates within a
// minute without adding a DB round-trip to every chat message.

// deno-lint-ignore no-explicit-any
type DB = any;

const TTL_MS = 60_000;
let cache: { value: boolean; expiresAt: number } | null = null;

/** Reads `app_config.kokomombo`. Cached for 60s. Never throws — on error it
 *  returns the last known value, or false if none. */
export async function isReviewModeOn(db: DB): Promise<boolean> {
  const now = Date.now();
  if (cache && cache.expiresAt > now) return cache.value;
  try {
    const { data } = await db
      .from("app_config")
      .select("bool_value")
      .eq("key", "kokomombo")
      .maybeSingle();
    const value = data?.bool_value === true;
    cache = { value, expiresAt: now + TTL_MS };
    return value;
  } catch (e) {
    console.error("isReviewModeOn: app_config read failed:", String(e));
    return cache?.value ?? false;
  }
}

/** Combines the client-sent flag with the DB flag. The DB flag can only turn
 *  review mode ON, never off — a stale/malicious client cannot escape it. */
export async function resolveReviewMode(db: DB, clientFlag: unknown): Promise<boolean> {
  if (clientFlag === true) return true;
  return await isReviewModeOn(db);
}
