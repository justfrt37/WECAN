-- supabase/migrations/023_memory_recurrence_and_cap.sql
--
-- Two additions to `memories`, both in service of extraction quality:
--
-- 1. `last_mentioned_at` / `mention_count` — extraction (chat/index.ts,
--    voice-call-end/index.ts) now sees dated memories and is told to merge a
--    recurring fact into its existing row (bumping these) instead of
--    inserting a near-duplicate row every time the user restates it.
--    `created_at` keeps meaning "first seen" throughout a memory's life.
--
-- 2. `match_memories` now also returns `mention_count` — needed by the
--    insert-time embedding-similarity dedup safety net in
--    applyMemoryExtraction (catches near-duplicates the extraction LLM's own
--    numbered-list judgment misses), which bumps the matched row's count in
--    one round trip instead of a separate select.

alter table memories add column if not exists last_mentioned_at timestamptz;
update memories set last_mentioned_at = coalesce(last_mentioned_at, created_at) where last_mentioned_at is null;
alter table memories alter column last_mentioned_at set default now();
alter table memories alter column last_mentioned_at set not null;

alter table memories add column if not exists mention_count int not null default 1;

drop function if exists match_memories(uuid, vector, int, float);

create or replace function match_memories(
  p_conversation_id uuid,
  p_query_embedding vector(384),
  p_match_count int default 5,
  p_similarity_threshold float default 0.75
)
returns table (id uuid, content text, similarity float, mention_count int)
language sql stable as $$
  select m.id, m.content,
         1 - (m.embedding <=> p_query_embedding) as similarity,
         m.mention_count
  from memories m
  where m.conversation_id = p_conversation_id
    and m.superseded_at is null
    and m.embedding is not null
    and 1 - (m.embedding <=> p_query_embedding) >= p_similarity_threshold
  order by m.embedding <=> p_query_embedding
  limit p_match_count;
$$;
