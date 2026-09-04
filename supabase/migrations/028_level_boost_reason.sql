-- supabase/migrations/028_level_boost_reason.sql
--
-- level-boost/index.ts charges tokens with p_reason: "level_boost", which was
-- never added to token_transactions_reason_check. charge_tokens() therefore
-- raises a check-constraint violation on the ledger insert, the whole plpgsql
-- function rolls back, the RPC returns null, and the edge function reports a
-- false "insufficient_tokens" (402) regardless of the user's real balance or
-- subscription tier. Identical failure mode to migration 025 (character_creation).
-- Confirmed 2026-09-02: a Pro Max account with ~7k tokens could not boost.

alter table token_transactions drop constraint token_transactions_reason_check;
alter table token_transactions add constraint token_transactions_reason_check
  check (reason in ('message', 'voice', 'photo', 'streak', 'purchase',
                    'subscription_grant', 'welcome', 'debug', 'character_creation',
                    'level_boost'));
