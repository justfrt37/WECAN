-- supabase/migrations/006_dev_token_tools.sql
-- TEMPORARY — supports the Profile tab's dev test panel (add/remove tokens,
-- simulate subscribing). Delete this migration's function + the 'debug'
-- reason once real RevenueCat/IAP purchases are wired up.

alter table token_transactions drop constraint token_transactions_reason_check;
alter table token_transactions add constraint token_transactions_reason_check
  check (reason in ('message', 'voice', 'photo', 'streak', 'purchase', 'subscription_grant', 'welcome', 'debug'));

-- Unlike charge_tokens, this never rejects on insufficient balance — clamps
-- at 0 instead. Only for the dev "-1000 tokens" test button.
create or replace function debug_adjust_balance(p_user_id uuid, p_delta int)
returns int
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
    set balance = greatest(0, balance + p_delta), updated_at = now()
    where user_id = p_user_id
    returning balance into v_new_balance;

  insert into token_transactions (user_id, delta, reason)
  values (p_user_id, p_delta, 'debug');

  return v_new_balance;
end;
$$;
