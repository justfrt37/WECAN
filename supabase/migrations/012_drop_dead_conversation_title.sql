-- Migration 011: drop dead conversations.title column
--
-- Never written by any edge function (conversations rows are inserted with
-- just user_id/character_id — see chat/index.ts) and never read anywhere in
-- the app. Chat list display name comes from the joined character's name,
-- not this column.

alter table conversations drop column if exists title;
