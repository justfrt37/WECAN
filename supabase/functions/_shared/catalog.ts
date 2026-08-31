// supabase/functions/_shared/catalog.ts
//
// ÜRÜN KATALOĞUNUN TEK DOĞRULUK KAYNAĞI: hangi ürün kaç token verir, hangi
// tier'a karşılık gelir.
//
// Neden yalnızca sunucuda: bu değerler para karşılığı verilen bir şeyi
// belirliyor. İstemcide bir kopyası durduğu sürece (eski `PlummCatalog`)
// iki risk vardı — (1) iki kopya birbirinden kayabilir ve kullanıcı satın
// aldığından farklı miktar alabilir, (2) istemci kaynaklı bir miktar
// sunucuya "şu kadar ver" diye geçirilebilir. Artık istemci miktarı ASLA
// göndermiyor; yalnızca GÖSTERMEK için `catalog` fonksiyonundan okuyor
// (bkz. supabase/functions/catalog, Plumm/Services/CatalogService.swift).

/// Tek seferlik token paketleri (consumable): ürün id -> verilen token.
export const TOKEN_PACKS: Record<string, number> = {
  token_100: 100,
  token_250: 250,
  token_500: 500,
  token_1000: 1000,
  token_2000: 2000,
  token_5000: 5000,
};

/// Abonelik ürününün DÖNEM BAŞINA verdiği token.
export const SUBSCRIPTION_TOKENS: Record<string, number> = {
  weekly_pro_normal: 250, monthly_pro_default: 1000, yearly_pro_normal: 12000,
  weekly_pro_plus: 500, monthly_pro_plus: 2000, yearly_pro_plus: 25000,
  weekly_pro_max: 750, monthly_pro_max: 3000, yearly_pro_max: 35000,
};

/// Abonelik ürünü -> tier. `subscriptions.tier` check constraint'iyle
/// (006_token_system.sql) ve RevenueCat entitlement id'leriyle AYNI kalmalı.
export const PRODUCT_TIER: Record<string, string> = {
  weekly_pro_normal: "pro", monthly_pro_default: "pro", yearly_pro_normal: "pro",
  weekly_pro_plus: "pro_plus", monthly_pro_plus: "pro_plus", yearly_pro_plus: "pro_plus",
  weekly_pro_max: "max", monthly_pro_max: "max", yearly_pro_max: "max",
};

/// Tier'ın haftalık token'ı — ürün id'si tanınmadığında kullanılan yedek.
export const WEEKLY_TOKENS: Record<string, number> = {
  pro: 1000, pro_plus: 2500, max: 6000,
};

export function isTokenPack(productId: string): boolean {
  return productId in TOKEN_PACKS;
}

/// Ürünün verdiği token — paket ya da abonelik, hangisiyse. Tanınmayan ürün 0.
export function tokensFor(productId: string): number {
  return TOKEN_PACKS[productId] ?? SUBSCRIPTION_TOKENS[productId] ?? 0;
}

/// İstemciye gönderilen katalog gövdesi (bkz. functions/catalog).
export function catalogPayload() {
  return {
    tokenPacks: TOKEN_PACKS,
    subscriptionTokens: SUBSCRIPTION_TOKENS,
    productTier: PRODUCT_TIER,
  };
}
