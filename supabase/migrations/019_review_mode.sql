-- 013_review_mode.sql
-- Review Mode — App Store inceleme sürecinde uygulamanın daha "güvenli" bir
-- karakter seti göstermesi için uzaktan kontrol edilen anahtar + ayrı tablo.
-- İstemci tarafı: Plumm/Services/ReviewModeService.swift
--
-- Anahtar `app_config.kokomombo` TRUE olduğunda uygulama karakterleri
-- `characters` yerine `characters_review` tablosundan çeker.

-- characters ile birebir aynı yapı (kolonlar, defaultlar, NOT NULL, PK).
create table if not exists public.characters_review (like public.characters including all);
alter table public.characters_review enable row level security;
drop policy if exists "characters_review public read" on public.characters_review;
create policy "characters_review public read" on public.characters_review for select using (true);

-- Uzaktan feature-flag deposu (key/value). Anahtar adı bilerek belirsiz: "kokomombo".
create table if not exists public.app_config (
  key        text primary key,
  bool_value boolean not null default false
);
alter table public.app_config enable row level security;
drop policy if exists "app_config public read" on public.app_config;
create policy "app_config public read" on public.app_config for select using (true);

insert into public.app_config (key, bool_value) values ('kokomombo', false)
  on conflict (key) do nothing;
