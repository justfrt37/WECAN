-- 029_subscription_grants.sql
--
-- Abonelik dönem grant'larının kalıcı defteri.
--
-- SORUN: idempotency anahtarı bugüne kadar `subscriptions.current_period_start`
-- idi — yani token verilip verilmediğinin kaydı, o token'ı veren satırın KENDİ
-- içinde tutuluyordu. Satır silinince kanıt da siliniyor ve aynı dönem yeniden
-- "yeni" sayılıp grant TEKRAR veriliyordu.
--
-- Canlı örnek (2026-09-05): tek bir yearly_pro_max dönemi (19:03:34 -> ertesi
-- gün 07:03:34) için 19:03, 19:05, 19:07, 19:09 ve 19:11'de beş kez +35000 =
-- 175.000 token. Aradaki tek fark, `subscriptions` satırının elle silinmesiydi.
-- Aynı açık üretimde de gerçek: satırı temizleyen herhangi bir bakım/hata,
-- webhook ile istemci senkronunun yarışı, ya da tier düşürmede satırın
-- sıfırlanması aynı sonucu verir — ve bu gerçek para.
--
-- ÇÖZÜM: grant kaydı AYRI ve yalnızca eklenen bir tabloda. `subscriptions`
-- satırına ne olursa olsun (silinsin, tier'ı değişsin, dönemi sıfırlansın)
-- bir dönem yalnızca BİR KEZ token verebilir. Birincil anahtarın kendisi
-- kısıtı uyguluyor; eşzamanlı iki çağrıdan biri çakışıp düşüyor, yani
-- kilit/okuma-yazma yarışı da imkânsız.
--
-- Aynı desen tek seferlik satın almalarda zaten kullanılıyor
-- (bkz. 027_token_purchases.sql, mağaza işlem kimliğiyle anahtarlı).

create table if not exists subscription_grants (
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id text not null,
  period_start timestamptz not null,
  tokens integer not null,
  created_at timestamptz not null default now(),
  -- Bir kullanıcı + ürün + dönem = en fazla bir grant.
  primary key (user_id, product_id, period_start)
);

create index if not exists subscription_grants_user_id_idx on subscription_grants(user_id);

-- Yalnızca edge function'lar (service_role) dokunur; istemcinin okumasına
-- gerek yok (bakiye `token_balances`'tan geliyor). RLS açık, policy YOK —
-- token_purchases / call_sessions ile aynı desen.
alter table subscription_grants enable row level security;
