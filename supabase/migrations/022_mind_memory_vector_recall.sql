-- supabase/migrations/022_mind_memory_vector_recall.sql
--
-- Wires up the pgvector column on `memories` that's existed since the
-- original schema but was never populated or queried — retrieval always
-- did `select * where conversation_id = ...` with no similarity filtering.
-- Switches embedding dimension from the original 1536 (OpenAI-shaped) to
-- 384 (gte-small, Supabase's free built-in embedding model — no OpenAI
-- dependency). No existing memory rows have a populated embedding (checked
-- 2026-08-13: 1 row total, embedding null), so this is a safe direct type
-- change, no data migration needed.

alter table memories
  alter column embedding type vector(384);

alter table memories
  add column if not exists superseded_at timestamptz;

drop index if exists memories_embedding_idx;
create index memories_embedding_idx
  on memories using hnsw (embedding vector_cosine_ops);

drop function if exists match_memories(uuid, vector, int);

create or replace function match_memories(
  p_conversation_id uuid,
  p_query_embedding vector(384),
  p_match_count int default 5,
  p_similarity_threshold float default 0.75
)
returns table (id uuid, content text, similarity float)
language sql stable as $$
  select m.id, m.content,
         1 - (m.embedding <=> p_query_embedding) as similarity
  from memories m
  where m.conversation_id = p_conversation_id
    and m.superseded_at is null
    and m.embedding is not null
    and 1 - (m.embedding <=> p_query_embedding) >= p_similarity_threshold
  order by m.embedding <=> p_query_embedding
  limit p_match_count;
$$;
