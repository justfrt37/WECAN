// supabase/functions/purchase-tokens/index.ts
//
// Tek seferlik token paketi (consumable) satın almasını SUNUCUDA doğrular ve
// tam olarak hak edilen kadar token verir — ne eksik ne fazla.
//
// Kapatılan iki hata:
//   1) Token paketi grant'ı istemcide `#if DEBUG` bloğundaydı
//      (PurchaseService.purchase → debugGrantTokens). Release/TestFlight
//      build'inde blok derlemeye HİÇ girmediği için kullanıcı 100 token satın
//      alıyor ve sıfır token alıyordu (bkz. kullanıcı raporu).
//   2) Miktar istemciden geliyordu (`{"action":"grant","amount":N}` →
//      dev-token-tools). İstemcinin söylediği kadar token veren bir uç nokta,
//      istemci ele geçirildiğinde sınırsız token demektir. Burada miktar
//      YALNIZCA sunucudaki katalogdan okunuyor; istek gövdesinde miktar
//      alanı hiç yok.
//
// Doğruluk kaynağı RevenueCat REST API (secret key, sunucu tarafı): kullanıcı
// adına gerçekten kaydedilmiş `non_subscriptions` işlemleri okunur. İstemcinin
// "satın aldım" iddiası tetikleyiciden ibarettir.
//
// Idempotency: her işlem `token_purchases.id` (mağaza işlem kimliği) birincil
// anahtarıyla yazılır. Aynı işlem ikinci kez işlenmeye çalışılırsa insert
// çakışır ve token VERİLMEZ — eşzamanlı iki çağrıda bile (aboneliklerdeki
// çift-grant hatası tam da böyle bir kısıt olmadığı için oluşmuştu).
//
// Auth: Supabase user JWT. RevenueCat app_user_id ile aynı string
// (Purchases.shared.logIn(uid), bkz. PurchaseService.configure).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { TOKEN_PACKS } from "../_shared/catalog.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RC_SECRET = Deno.env.get("REVENUECAT_SECRET_KEY");

const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function userIdFromJWT(authHeader: string | null): string | null {
  if (!authHeader?.startsWith("Bearer ")) return null;
  const parts = authHeader.slice(7).split(".");
  if (parts.length < 2) return null;
  try {
    let b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    while (b64.length % 4) b64 += "=";
    return JSON.parse(atob(b64)).sub ?? null;
  } catch {
    return null;
  }
}

async function currentBalance(uid: string): Promise<number> {
  const { data } = await db.from("token_balances").select("balance").eq("user_id", uid).maybeSingle();
  return data?.balance ?? 0;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  const uid = userIdFromJWT(req.headers.get("Authorization"));
  if (!uid) return json({ error: "unauthorized" }, 401);
  if (!RC_SECRET) return json({ error: "server_misconfigured: REVENUECAT_SECRET_KEY missing" }, 500);

  // Yeni tamamlanan satın almanın mağaza işlem kimliği. Verilirse YALNIZCA o
  // işlem işlenir — kullanıcı ne aldıysa o kadar token alır, ne eksik ne fazla.
  //
  // Verilmezse (restore akışı) RC'deki tüm tek-seferlik satın almalar taranır.
  // Bu bilinçli bir fark: restore'un işi zaten ödenmiş ama verilmemiş olanı
  // geri getirmek. Ama satın alma anında bunu yapmak yanlış olurdu — canlı
  // örnekte bir token_100 alımı, geçmişteki hiç verilmemiş 4x100 + 2x5000'i de
  // aynı anda yükleyip 10.400 token eklemişti (bkz. kullanıcı raporu).
  //
  // Kimlik yalnızca HANGİ işlem sorusunu cevaplıyor; KAÇ TOKEN sorusunu değil.
  // Miktar her zaman sunucu kataloğundan okunuyor ve işlem RC'de bu kullanıcı
  // adına gerçekten kayıtlı değilse hiçbir şey verilmiyor.
  let onlyTransactionId: string | null = null;
  try {
    const body = await req.json();
    if (typeof body?.transactionId === "string" && body.transactionId) {
      onlyTransactionId = body.transactionId;
    }
  } catch { /* gövdesiz çağrı = restore taraması */ }

  // RevenueCat'in bu kullanıcı için kaydettiği TÜM tek seferlik satın almalar.
  const rcResp = await fetch(
    `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(uid)}`,
    { headers: { Authorization: `Bearer ${RC_SECRET}`, "Content-Type": "application/json" } },
  );
  if (!rcResp.ok) return json({ error: `revenuecat_error_${rcResp.status}` }, 502);
  const rc = await rcResp.json();
  const nonSubs: Record<string, Array<{ id?: string; store_transaction_id?: string; purchase_date?: string }>> =
    rc?.subscriber?.non_subscriptions ?? {};

  let granted = 0;
  const grantedIds: string[] = [];

  for (const [productId, purchases] of Object.entries(nonSubs)) {
    // Miktar YALNIZCA sunucu kataloğundan. Tanınmayan ürün atlanır (0 token
    // vermek yerine hiç işlememek: katalogda olmayan bir ürün için ne
    // vereceğimizi bilmiyoruz, sessizce 0 yazmak defteri kirletirdi).
    const amount = TOKEN_PACKS[productId];
    if (!amount) continue;

    for (const p of purchases ?? []) {
      const txId = p?.id;
      if (!txId) continue;
      // Belirli bir işlem istendiyse diğerlerine dokunma. Eşleşme RC'nin
      // kaydı üzerinden yapılıyor, yani istemcinin uydurduğu bir kimlik
      // hiçbir şey açmaz.
      //
      // İKİ kimlik de karşılaştırılıyor çünkü bunlar farklı şeyler:
      // `id` RevenueCat'in kendi kimliği ("o1_AVcIO9Z4..."), istemcinin
      // gönderdiği `transactionIdentifier` ise StoreKit'in kimliği (sayısal,
      // RC'de `store_transaction_id`). Yalnızca `id`ye bakmak her satın almada
      // eşleşmeme → grant=0 demekti (bkz. kullanıcı logu: 4 denemede de +0).
      // Satır anahtarı olarak RC'nin `id`si kullanılmaya devam ediyor:
      // idempotency anahtarının tek ve kararlı olması gerekiyor.
      const storeTxId = p?.store_transaction_id;
      if (onlyTransactionId && onlyTransactionId !== storeTxId && onlyTransactionId !== txId) continue;

      // Idempotency kapısı: insert ÖNCE, grant SONRA. Çakışırsa bu işlem
      // zaten işlenmiştir ve token verilmez.
      const { data: inserted, error } = await db.from("token_purchases")
        .upsert(
          { id: txId, user_id: uid, product_id: productId, tokens: amount },
          { onConflict: "id", ignoreDuplicates: true },
        )
        .select("id");
      if (error) continue;
      if (!inserted?.length) continue;   // daha önce işlenmiş

      await db.rpc("grant_tokens", { p_user_id: uid, p_amount: amount, p_reason: "purchase" });
      granted += amount;
      grantedIds.push(txId);
    }
  }

  // Bakiye HER ZAMAN sunucudan dönüyor (grant olmasa bile): istemci bakiyeyi
  // kendi hesaplamıyor, bu yanıtı yazıyor — böylece ekrandaki sayı ile
  // veritabanı asla ayrışmıyor.
  // `seen`: RC'nin bu kullanıcı için bildiği tüm tek-seferlik işlem kimlikleri.
  // İstenen kimlik hiçbiriyle eşleşmediğinde (grant=0) sebebi tek bakışta
  // görülsün diye dönüyor — aksi halde "neden 0 verdi" sorusu sunucu logları
  // olmadan cevaplanamıyordu.
  const seen = Object.values(nonSubs).flat().map((p) => ({ id: p?.id, store: p?.store_transaction_id }));
  return json({ granted, grantedIds, requested: onlyTransactionId, seen, balance: await currentBalance(uid) });
});
