-- supabase/migrations/023_drop_dead_columns.sql
--
-- Two leftover columns from earlier iterations of the system, confirmed
-- dead by auditing every read/write site in the app + edge functions
-- (2026-08-13):
--
-- characters.relationship_level: leftover from before per-conversation
-- leveling existed. Only ever written once at insert (always 0), read in
-- exactly one place (chat-image/index.ts) which immediately discarded it
-- in favor of conversations.relationship_level (the real per-user value) —
-- see that function's updated comment.
--
-- character_photos.is_pro: real curator-set data (628 rows true out of
-- 2854), meant to gate photos behind the Pro tier, but never enforced
-- anywhere — the in-chat photo-pool query never filtered on it, and no
-- client code reads it either. Confirmed vestigial, not a live gate to fix.

alter table characters drop column if exists relationship_level;
alter table character_photos drop column if exists is_pro;
