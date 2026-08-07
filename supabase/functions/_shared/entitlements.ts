// supabase/functions/_shared/entitlements.ts
//
// Abonelik seviyesine (tier) bağlı İŞ KURALLARI — KAYNAK-DOĞRU yer burasıdır.
// İstemci (Plumm/Services/PurchaseService.swift → SubscriptionTier) bu kuralların
// bir AYNASINI tutar (paywall'da göstermek + boşuna istek atmamak için); asıl
// karar her zaman sunucuda verilir.
//
// Kurallar (bkz. kullanıcı talebi):
//   ┌──────────┬──────────────────────┬─────────────────┐
//   │ tier     │ haftalık karakter    │ ses (mesaj+arama)│
//   ├──────────┼──────────────────────┼─────────────────┤
//   │ pro      │ 1                    │ YOK             │
//   │ pro_plus │ 5                    │ VAR             │
//   │ max      │ sınırsız             │ VAR             │
//   └──────────┴──────────────────────┴─────────────────┘
// Abonelik yoksa (none) hiçbiri yok.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

export type Tier = "none" | "pro" | "pro_plus" | "max";

/// Haftalık karakter yaratma hakkı. `Infinity` = sınırsız (max).
export const WEEKLY_CHARACTER_LIMIT: Record<Tier, number> = {
  none: 0,
  pro: 1,
  pro_plus: 5,
  max: Infinity,
};

/// Ses özellikleri (sesli mesaj + sesli arama) yalnızca pro_plus ve max'te.
export const VOICE_TIERS: Tier[] = ["pro_plus", "max"];

export function canUseVoice(tier: Tier): boolean {
  return VOICE_TIERS.includes(tier);
}

/// Kullanıcının O AN aktif (dönemi bitmemiş) aboneliği. Yoksa "none".
export async function activeTier(db: SupabaseClient, uid: string): Promise<Tier> {
  const { data } = await db
    .from("subscriptions")
    .select("tier")
    .eq("user_id", uid)
    .gte("current_period_end", new Date().toISOString())
    .maybeSingle();
  const tier = data?.tier as Tier | undefined;
  return tier && tier in WEEKLY_CHARACTER_LIMIT ? tier : "none";
}

/// Ses gerektiren fonksiyonların (voice-message-tts, voice-call-start) ortak
/// kapısı. Geçerse null döner; geçmezse istemciye dönülecek gövde + durum kodu.
/// 403 + `required_tier` → istemci doğru paywall'ı açabilir.
export async function requireVoiceEntitlement(
  db: SupabaseClient,
  uid: string,
): Promise<{ body: { error: string; tier: Tier; required_tier: string }; status: number } | null> {
  const tier = await activeTier(db, uid);
  if (canUseVoice(tier)) return null;
  return {
    body: { error: "voice_requires_pro_plus", tier, required_tier: "pro_plus" },
    status: 403,
  };
}
