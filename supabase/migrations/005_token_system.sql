-- supabase/migrations/005_token_system.sql

create table if not exists token_balances (
  user_id uuid primary key references auth.users(id) on delete cascade,
  balance integer not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists token_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  delta integer not null,
  reason text not null check (reason in ('message', 'voice', 'photo', 'streak', 'purchase', 'subscription_grant', 'welcome')),
  created_at timestamptz not null default now()
);
create index if not exists token_transactions_user_id_idx on token_transactions(user_id);

create table if not exists streak_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  current_streak integer not null default 0,
  last_claim_at timestamptz,
  last_claimed_local_date text
);

-- Populated by a future RevenueCat webhook (see design doc "Dependencies").
-- Empty today — every check against this table correctly finds no active
-- subscription until that webhook exists, matching current app behavior.
create table if not exists subscriptions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  tier text not null check (tier in ('pro', 'pro_plus', 'max')),
  current_period_start timestamptz not null,
  current_period_end timestamptz not null,
  updated_at timestamptz not null default now()
);

alter table token_balances enable row level security;
alter table token_transactions enable row level security;
alter table streak_state enable row level security;
alter table subscriptions enable row level security;

create policy "select own token balance" on token_balances for select using (user_id = auth.uid());
create policy "select own token transactions" on token_transactions for select using (user_id = auth.uid());
create policy "select own streak state" on streak_state for select using (user_id = auth.uid());
create policy "select own subscription" on subscriptions for select using (user_id = auth.uid());

-- Atomically deducts tokens if (and only if) the balance can cover it.
-- Returns false (no-op, no ledger row) on insufficient balance — callers
-- must check the return value and reject the paid action's response.
create or replace function charge_tokens(p_user_id uuid, p_amount int, p_reason text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new_balance int;
begin
  insert into token_balances (user_id, balance)
  values (p_user_id, 0)
  on conflict (user_id) do nothing;

  update token_balances
    set balance = balance - p_amount, updated_at = now()
    where user_id = p_user_id and balance >= p_amount
    returning balance into v_new_balance;

  if v_new_balance is null then
    return false;
  end if;

  insert into token_transactions (user_id, delta, reason)
  values (p_user_id, -p_amount, p_reason);

  return true;
end;
$$;

-- Adds tokens (streak grants, purchases, subscription drips, the one-time
-- welcome grant). No balance check needed — always succeeds.
create or replace function grant_tokens(p_user_id uuid, p_amount int, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into token_balances (user_id, balance)
  values (p_user_id, p_amount)
  on conflict (user_id) do update set balance = token_balances.balance + p_amount, updated_at = now();

  insert into token_transactions (user_id, delta, reason)
  values (p_user_id, p_amount, p_reason);
end;
$$;
