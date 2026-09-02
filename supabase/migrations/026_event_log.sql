-- supabase/migrations/026_event_log.sql
--
-- Full in-app analytics event log (bkz. kullanıcı talebi 2026-09-01) — onboarding
-- funnel, paywall funnel, mesajlaşma aktivitesi, giriş sıklığı, özellik kullanım
-- oranı. Amplitude/PostHog yerine tek bir kendi tablomuz: joinable directly
-- against subscriptions/token_balances/conversations via plain SQL.

create table if not exists event_log (
  id          bigint generated always as identity primary key,
  user_id     uuid,                    -- auth.uid() at log time (anon or real)
  device_id   uuid not null,           -- Keychain-persisted, survives reinstall
  session_id  uuid not null,           -- one per app open (cold launch or resume-from-background)
  event_name  text not null,
  properties  jsonb not null default '{}',
  app_version text,
  platform    text not null default 'ios',
  created_at  timestamptz not null default now()
);

create index if not exists event_log_user_created_idx on event_log (user_id, created_at);
create index if not exists event_log_event_created_idx on event_log (event_name, created_at);
create index if not exists event_log_session_idx on event_log (session_id);
create index if not exists event_log_properties_gin_idx on event_log using gin (properties);

alter table event_log enable row level security;

-- Append-only from the client's perspective: any authenticated (incl. anon)
-- user may INSERT their own rows, nobody can SELECT/UPDATE/DELETE via the
-- client — analysis only happens server-side (service_role bypasses RLS).
drop policy if exists "event_log_own_insert" on event_log;
create policy "event_log_own_insert" on event_log
  for insert to authenticated with check (auth.uid() = user_id);
