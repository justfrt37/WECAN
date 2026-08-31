-- supabase/migrations/025_nicknames_and_level_boost.sql
--
-- Nicknames (Pro+/Max only, see _shared/entitlements.ts): both directions,
-- scoped per (user, character) conversation like everything else here.
-- character_nickname is cosmetic display-only (never reaches a prompt);
-- user_nickname flows into chat/index.ts's system prompt (see set-nickname
-- edge function for its regex-only injection check, same class as
-- conversation_behaviors).
--
-- Level-boost (any tier, token-gated only) writes relationship_level/
-- level_progress directly — no new column needed for it.

alter table conversations add column if not exists character_nickname text;
alter table conversations add column if not exists user_nickname text;
