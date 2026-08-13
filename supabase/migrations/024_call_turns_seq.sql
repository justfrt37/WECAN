-- supabase/migrations/024_call_turns_seq.sql
--
-- call_turns ordering relied purely on created_at, which a code comment in
-- voice-call-llm-webhook already flagged as unreliable: separate insert()
-- calls CAN still land the same timestamp under load, and — the bigger
-- real-world case, confirmed by inspecting an actual transcript
-- (2026-08-13) — each conversational turn is logged by a SEPARATE HTTP
-- invocation of the webhook (ElevenLabs calls it once per turn), fired via
-- fire-and-forget EdgeRuntime.waitUntil with no ordering guarantee between
-- invocations. An identity column gives a strictly monotonic, Postgres-
-- assigned insert-order sequence to order by instead of wall-clock time.

alter table call_turns add column if not exists seq bigint generated always as identity;
create index if not exists call_turns_session_seq_idx on call_turns(call_session_id, seq);
