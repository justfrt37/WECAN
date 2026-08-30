// Shared RevenueCat verification + subscriptions-table sync logic.
// Used by both sync-subscription (client-triggered, pull) and
// revenuecat-webhook (RC-triggered, push) so there's exactly one place that
// decides what "the truth" is: always a fresh call to RC's REST API with the
// secret key, never the client's or the webhook payload's own claims about
// tier — those are just triggers to go re-check.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { PRODUCT_TIER, SUBSCRIPTION_TOKENS, WEEKLY_TOKENS } from "./catalog.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
export const RC_SECRET = Deno.env.get("REVENUECAT_SECRET_KEY");

export const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

// Entitlement identifier → tier. Highest wins if several are active.
const TIER_PRIORITY = ["max", "pro_plus", "pro"];
// Ürün→token/tier eşlemeleri artık _shared/catalog.ts'te (TEK kaynak) —
// buradaki yerel kopyalar kaldırıldı, istemcideki kopya da (PlummCatalog) öyle.
const PRODUCT_TOKENS = SUBSCRIPTION_TOKENS;

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
    // Satırı SİLMİYORUZ. Silmek idempotency anahtarını (current_period_start)
    // yok ediyordu: bir sonraki sync aynı dönemi "yeni" sanıp aynı grant'ı
    // TEKRAR veriyordu (canlı defterde aynı dönem için 9 kez +12000 —
    // bkz. kullanıcı raporu). Tier'ı none'a çekmek yeterli; dönem anahtarı
    // yerinde kalır. `subscriptions.tier` check constraint'i 'none' kabul
    // etmediği için satır varsa güncellenir, yoksa hiç oluşturulmaz.
    await db.from("subscriptions")
      .update({ current_period_end: new Date(now).toISOString(), updated_at: new Date().toISOString() })
      .eq("user_id", uid);
    return { tier: "none", balance: await currentBalance(uid), debug };
  }

  const periodStart = ent.purchase_date ?? new Date().toISOString();
  const periodEnd = ent.expires_date ?? new Date(now + 365 * 86_400_000).toISOString();

  // ATOMİK dönem talebi. Eskiden bu bir "oku → yaz → ver" dizisiydi ve arada
  // kilit yoktu: eşzamanlı iki çağrı (syncWithServerRetrying 4 kez deniyor,
  // ayrıca purchase()/restore() ve webhook aynı anda tetikleyebiliyor) ikisi
  // de `existing`i güncellenmeden okuyup ikisi de "yeni dönem" sanıyor ve
  // ikisi de grant veriyordu — canlı defterde 1 saniye arayla iki +12000
  // (bkz. kullanıcı raporu, 9 kez tekrarlanan grant).
  //
  // Şimdi kararı VERİTABANI veriyor: dönem anahtarını yalnızca FARKLIYSA
  // güncelleyen koşullu bir UPDATE ve satır yoksa çakışmada sessizce düşen
  // bir INSERT. İkisinden de dönen satır sayısı 1 ise bu çağrı dönemi ilk kez
  // talep etmiştir; eşzamanlı diğer çağrı 0 satır alır ve grant vermez.
  const row = {
    user_id: uid,
    tier: activeTier,
    current_period_start: periodStart,
    current_period_end: periodEnd,
    updated_at: new Date().toISOString(),
  };

  const { data: updated } = await db.from("subscriptions")
    .update(row)
    .eq("user_id", uid)
    .neq("current_period_start", periodStart)
    .select("user_id");

  let isNewPeriod = (updated?.length ?? 0) > 0;

  if (!isNewPeriod) {
    // Ya satır hiç yok (ilk abonelik) ya da dönem zaten bizimki (grant verilmiş).
    // İlkini ayırt etmek için çakışmayı yok sayan bir INSERT deniyoruz:
    // satır zaten varsa 0 satır döner ve grant verilmez.
    const { data: inserted } = await db.from("subscriptions")
      .upsert(row, { onConflict: "user_id", ignoreDuplicates: true })
      .select("user_id");
    isNewPeriod = (inserted?.length ?? 0) > 0;

    if (!isNewPeriod) {
      // Satır var ve dönem aynı → grant verilmeyecek. AMA tier değişmiş
      // olabilir: kullanıcı aynı dönem içinde Pro'dan Pro+'a yükseltirse
      // yukarıdaki koşullu UPDATE (`.neq(current_period_start, ...)`)
      // hiç çalışmıyor ve satır `pro` olarak kalıyordu — kullanıcı parayı
      // ödüyor, sunucu hâlâ eski tier'ı görüyordu (bkz. kullanıcı raporu:
      // "satın alımı yaptığımda backend'deki üyeliğim pro'da kalıyor").
      //
      // Tier ile GRANT'ı ayırmak gerekiyordu: tier gerçeğin aynası, her
      // zaman yazılmalı; token grant'ı ise dönem başına bir kez.
      await db.from("subscriptions")
        .update({ tier: activeTier, current_period_end: periodEnd, updated_at: new Date().toISOString() })
        .eq("user_id", uid);
    }
  }

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
