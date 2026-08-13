-- supabase/migrations/025_character_creation_reason.sql
--
-- create-character/index.ts charges CREATION_COST tokens with
-- p_reason: "character_creation" — not in the token_transactions_reason_check
-- allowlist, so charge_tokens() has been failing its own check constraint on
-- every single custom character creation (silent RPC failure -> `charged`
-- never true -> character deleted -> false "insufficient_tokens" shown to
-- the user regardless of actual balance). Confirmed live-broken 2026-08-13:
-- only 1 user-created character exists in the whole table.

alter table token_transactions drop constraint token_transactions_reason_check;
alter table token_transactions add constraint token_transactions_reason_check
  check (reason in ('message', 'voice', 'photo', 'streak', 'purchase', 'subscription_grant', 'welcome', 'debug', 'character_creation'));
