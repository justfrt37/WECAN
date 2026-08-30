// supabase/functions/catalog/index.ts
//
// Ürün kataloğunu (ürün id -> token / tier) istemciye verir.
//
// Neden var: bu eşlemeler eskiden İSTEMCİDE de duruyordu (`PlummCatalog`,
// Plumm/Services/PurchaseService.swift). İki kopya olması para karşılığı
// verilen bir miktarın iki farklı yerde tanımlı olması demekti; biri
// güncellenip diğeri unutulduğunda kullanıcı satın aldığından farklı miktar
// görüyor/alıyordu. Artık tek kaynak `_shared/catalog.ts` ve istemci
// miktarları YALNIZCA GÖSTERMEK için buradan okuyor — grant miktarını asla
// istemci belirlemiyor (bkz. functions/purchase-tokens).
//
// Auth: Supabase user JWT (anonim kullanıcı da olur). Katalog gizli veri
// değil, ama uç noktayı kimliksiz bırakmak için sebep de yok.

import { catalogPayload } from "../_shared/catalog.ts";

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

Deno.serve((req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  if (!userIdFromJWT(req.headers.get("Authorization"))) {
    return json({ error: "unauthorized" }, 401);
  }
  return json(catalogPayload());
});
