# Mind Memory — Vector Semantic Recall — Design

## Context

`memories` already has an unused `embedding vector(1536)` column and a `match_memories()` similarity RPC (`schema.sql`), scaffolded for OpenAI-shaped embeddings but never wired to any code path. Every retrieval today (`_shared/directiveHelpers.ts` → `fetchDirectiveMemoriesBehaviors`) just selects **all** rows for a `conversation_id` and dumps them into the prompt as a flat bulleted list, unranked and unfiltered:

```
[MEMORIES — facts to remember about the user/relationship]
- fact one
- fact two
...
```

This causes two problems: (1) as memory count grows per conversation, irrelevant facts get injected every turn regardless of what's currently being discussed, diluting the prompt and (2) the bulleted-list framing encourages the model to recite memories verbatim ("I remember you said...") rather than let them inform tone/reactions naturally.

Extraction already exists and works: `chat/index.ts`'s rolling summarization (triggered when `agedOut > summarizedCount`, i.e. once enough messages have aged past the active window) and `voice-call-end/index.ts`'s one-shot post-call extractor both call Grok with a "extract new atomic facts not already in this existing list" prompt and insert results into `memories`. Neither populates `embedding`.

Scale check (2026-08-13): 30 conversations, 262 messages, 1 memory row total — pre-launch, no meaningful data to migrate.

## Goal

Wire up real semantic recall: embed extracted memories, retrieve only the ones relevant to what's currently being discussed (top-k similarity, not "everything"), and inject them in a way that discourages the model from reciting them like a cheat sheet. Applies going forward to every conversation (new and existing) — no backfill needed given current scale.

## Non-goals (this pass)

- No graph/triplet structured fact store. At this scale, well-written short facts + vector similarity resolve direct fact-checks ("what's my job again?") without the complexity of a subject-predicate-object schema. Revisit only if fact-drift/contradiction actually shows up in practice post-launch.
- No change to `conversation_behaviors` — those are explicit user-stated preferences ("always call me babe", "no cursing"), a different job than fuzzy memory recall. They stay always-injected, unfiltered, as today.
- No backfill/reprocessing of the 1 existing memory row or past conversations' history into the new embedding path — it will simply have no embedding and be skipped by similarity retrieval until superseded or until that conversation naturally produces new (embedded) memories.
- No external paid embedding API (OpenAI etc.) — uses Supabase Edge Functions' built-in `Supabase.ai.Session("gte-small")`, which runs in-process (WASM) with no external network call and no API cost.
- No dynamic per-turn re-embedding of the same memory — embeddings are computed once at extraction time and are immutable until the memory is superseded.

## Architecture

**Schema changes** (new migration):
- `memories.embedding`: `vector(1536)` → `vector(384)` (gte-small's output dimension). Existing HNSW index (`memories_embedding_idx`, `vector_cosine_ops`) recreated at the new dimension.
- `memories.superseded_at timestamptz null` — soft-delete marker for facts a later extraction has explicitly contradicted (e.g. user's stated job changes). Retrieval and `match_memories()` both filter `superseded_at is null`.
- `match_memories()` updated to accept `p_conversation_id` (currently missing — it's unscoped by conversation in the existing signature) and to respect the new `superseded_at` filter and a `p_similarity_threshold` param.

**Extraction (extends existing code paths, no new trigger):**
- Same two call sites as today (`chat/index.ts` rolling summarization, `voice-call-end/index.ts` post-call extraction). Both already send the existing-memories list to Grok to avoid duplicate facts.
- Prompt addition: alongside `newMemories`, Grok also returns `staleIndexes` — indexes into the existing-memories list it was shown, for any existing facts the new content now contradicts. Response shape becomes:
  ```json
  {"newMemories": ["fact one", "fact two"], "staleIndexes": [2]}
  ```
- On response: mark `memories.superseded_at = now()` for rows at the given indexes (mapped back to their ids from the existing-memories query), then insert `newMemories` as new rows.
- Each newly inserted memory's `content` is embedded via `Supabase.ai.Session("gte-small")` (`.run(content, { mean_pool: true, normalize: true })`) in the same request, and the resulting vector stored on insert — no separate embedding pass/job.

**Retrieval (replaces the "select all" in `fetchDirectiveMemoriesBehaviors`):**
- Query text = the last 3 turns of the conversation (already available in `chat/index.ts`'s in-memory history array at the point memories are fetched; `voice-call-start` uses the greeting-generation context equivalent), concatenated into one string.
- Embed that once via the same `gte-small` session, then call `match_memories(p_conversation_id, p_query_embedding, p_match_count => 5, p_similarity_threshold => 0.75)`.
- No floor-fill: if nothing clears the threshold, no memories are injected that turn. Forcing in irrelevant facts to avoid an empty section is worse than omitting the section.
- `conversation_behaviors` retrieval is untouched (still "select all for conversation").

**Prompt injection (passive framing):**
Replace the current bulleted "[MEMORIES — facts to remember]" block (in `memoriesBlock()`, `_shared/directiveHelpers.ts`) with:
```
[INTERNAL CONTEXT — things you already know about them from before. Let this
color your tone/reactions naturally. Never announce or list these, never say
"I remember" unless it's the natural beat of the moment.]
- fact one
- fact two
```
Applied everywhere `memoriesBlock()` is used: `chat/index.ts`'s main system prompt build and reaction-system prompt build, and `voice-call-start/index.ts`'s system prompt build.

## Data Flow

1. Extraction (unchanged trigger points): Grok returns `{newMemories, staleIndexes}` → mark stale rows superseded → embed + insert new rows, all in the same function invocation that already runs today.
2. Per-turn retrieval (`chat/index.ts`, `voice-call-start/index.ts`): build last-3-turns query text → embed via `gte-small` → `match_memories()` scoped to `conversation_id`, threshold 0.75, top 5 → `memoriesBlock()` renders the passive-framed block → appended to system prompt exactly where the old unfiltered dump was.
3. Everything downstream (directive/behaviors fetch, prompt assembly, Grok chat call) is unchanged.

## Components Changed

| Component | Change |
|---|---|
| new migration (`supabase/migrations/`) | `memories.embedding` → `vector(384)`, recreate HNSW index; add `memories.superseded_at`; update `match_memories()` signature/body. |
| `_shared/directiveHelpers.ts` | `fetchDirectiveMemoriesBehaviors` takes a query-text param, embeds it, calls `match_memories` instead of `select *`; `memoriesBlock()` passive-framing rewrite; new small helper for `gte-small` embedding (shared by extraction + retrieval call sites). |
| `chat/index.ts` | Rolling-summarization extraction block: add `staleIndexes` handling + embed-on-insert. Call sites of `fetchDirectiveMemoriesBehaviors` pass last-3-turns text. |
| `voice-call-start/index.ts` | Call site of `fetchDirectiveMemoriesBehaviors` passes the last 3 messages from that conversation's `messages` table (chat history predating the call — a call has no turns of its own yet at start time), or omits the query (skip retrieval, empty memories block) if the conversation has no prior messages at all. |
| `voice-call-end/index.ts` | Post-call extractor: add `staleIndexes` handling + embed-on-insert, same as chat. |

## Performance

`gte-small` embedding runs in-process in the edge function (WASM, no network hop) and the HNSW query is scoped to a single conversation's small row set. Both comfortably clear the sub-100ms target at current and near-term scale (30 conversations, low hundreds of memories total). Not expected to be a real bottleneck; revisit only if a single conversation's memory count reaches the thousands.

## Testing

- Unit-level: seed a conversation with several `memories` rows (mixed relevant/irrelevant to a sample query), verify `match_memories` returns only rows above threshold, ordered by similarity, excluding `superseded_at` rows.
- Extraction: feed a transcript that contradicts an existing memory (e.g. existing "works as a barista" + new turn "I just started my nursing job"), verify `staleIndexes` marks the old row superseded and a new row is inserted with an embedding populated.
- End-to-end: manually run a real chat conversation past the summarization trigger, confirm system prompt's `[INTERNAL CONTEXT]` block contains only topically-relevant facts, and that the model doesn't recite them verbatim.
