-- 027_token_purchases.sql
--
-- Tek seferlik token paketi (consumable) satın almalarının defteri.
--
-- Neden gerekli: token paketleri bugüne kadar YALNIZCA istemcide, `#if DEBUG`
-- bloğunda veriliyordu (bkz. PurchaseService.purchase → debugGrantTokens).
-- Yani Release/TestFlight build'inde kullanıcı 100 token satın alıyor ve
-- HİÇ token almıyordu — parayı ödeyip ürünü almamak (bkz. kullanıcı raporu:
-- "100 token alıyorum ama doğru gelmiyor"). Sunucu tarafı akış bunu kapatıyor.
--
-- `id` = mağazanın işlem kimliği (RevenueCat `non_subscriptions[].id`).
-- Birincil anahtar olması grant'ı ATOMİK olarak idempotent yapıyor: aynı
-- işlem ikinci kez işlenmeye çalışılırsa insert çakışır ve token verilmez.
-- Abonelik grant'larındaki çift-verme hatası (aynı dönem için 9 kez +12000)
-- tam da böyle bir kısıt olmadığı için mümkün olmuştu.

create table if not exists token_purchases (
  id text primary key,                    -- store transaction id (RC non_subscriptions[].id)
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id text not null,
  tokens integer not null,
  created_at timestamptz not null default now()
);

create index if not exists token_purchases_user_id_idx on token_purchases(user_id);

-- Sadece edge function'lar (service_role) dokunur — istemcinin doğrudan
-- okumasına gerek yok (bakiye `token_balances`'tan geliyor), o yüzden RLS
-- açık ve policy YOK: aynı desen call_sessions/call_turns'te de kullanılıyor
-- (bkz. 017_voice_calls.sql).
alter table token_purchases enable row level security;
