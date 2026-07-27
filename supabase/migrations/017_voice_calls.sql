-- 017_voice_calls.sql
-- Real-time voice call feature — separate log from the normal `messages`
-- table (bkz. docs/superpowers/specs/2026-07-28-voice-call-design.md).
-- Client never queries these directly (no PostgREST access needed) — only
-- the voice-call-* edge functions (service_role) touch them, so RLS is
-- enabled with no policy, same pattern as conversation_behaviors/shot_templates
-- (bkz. migration 012_enable_rls.sql).

create table if not exists call_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  character_id uuid not null references characters(id) on delete cascade,
  conversation_id uuid references conversations(id) on delete cascade,
  status text not null default 'active', -- 'active' | 'ended'
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  last_checkpoint_seconds int not null default 0,
  tokens_charged int
);

create table if not exists call_turns (
  id uuid primary key default gen_random_uuid(),
  call_session_id uuid not null references call_sessions(id) on delete cascade,
  role text not null, -- 'user' | 'assistant'
  content text not null,
  audio_url text,
  created_at timestamptz not null default now()
);

create index if not exists call_sessions_user_status_idx on call_sessions(user_id, status);
create index if not exists call_turns_session_idx on call_turns(call_session_id, created_at);

alter table call_sessions enable row level security;
alter table call_turns enable row level security;
