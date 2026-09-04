-- supabase/migrations/024_jealousy_state.sql
--
-- Server-authoritative state for the reworked Jealousy notification system
-- (level-3+ gate, 6h cooldown + re-engagement gate for a fresh ping, one
-- escalated follow-up if unanswered, short jealous-mood decay once the user
-- answers the escalation). Same pattern as the existing ghosted_at/
-- manual_sleep_at/woken_up_at columns — client mirrors these locally for
-- scheduling, server is the durable source of truth across app restarts.

alter table conversations add column if not exists jealousy_sent_at timestamptz;
alter table conversations add column if not exists jealousy_stage smallint not null default 0;
alter table conversations add column if not exists jealousy_mood_turns_left smallint not null default 0;
