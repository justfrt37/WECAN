// supabase/functions/_shared/directiveHelpers.ts
//
// Character directive + memories + behaviors fetch, shared between chat/index.ts
// and voice-call-turn/index.ts — both need the exact same "what does this
// character know and how should it currently behave" assembly.

// Deno-agnostic minimal client type — callers pass their own `db` (createClient
// result) so this module never creates its own connection/env dependency.
type DB = ReturnType<typeof import("https://esm.sh/@supabase/supabase-js@2").createClient>;

// `Supabase.ai` is a global injected by the Supabase Edge Runtime (not an
// import) — no type declarations ship for it, hence the `declare`. Runs
// gte-small in-process via WASM: no network call, no API key, no cost.
declare const Supabase: {
  ai: { Session: new (model: string) => { run(input: string, opts: { mean_pool: boolean; normalize: boolean }): Promise<number[]> } };
};

export async function embedText(text: string): Promise<number[]> {
  const session = new Supabase.ai.Session("gte-small");
  return await session.run(text, { mean_pool: true, normalize: true });
}

const directiveCache = new Map<string, { directive: string; expiresAt: number }>();
const DIRECTIVE_TTL_MS = 5 * 60_000;

export async function fetchDirective(db: DB, characterId: string, role: string, level: number): Promise<string> {
  const key = `${characterId}:${role}:${level}`;
  const now = Date.now();
  const cached = directiveCache.get(key);
  if (cached && cached.expiresAt > now) return cached.directive;

  const { data: override } = await db
    .from("character_level_overrides")
    .select("directive")
    .eq("character_id", characterId)
    .eq("level", level)
    .maybeSingle();

  let directive: string;
  if (override?.directive) {
    directive = override.directive;
  } else {
    const { data: script } = await db
      .from("role_level_scripts")
      .select("directive")
      .eq("role", role)
      .eq("level", level)
      .maybeSingle();
    directive = script?.directive ?? `Relationship level ${level}/10. Be natural and warm.`;
  }

  directiveCache.set(key, { directive, expiresAt: now + DIRECTIVE_TTL_MS });
  return directive;
}

export async function fetchDirectiveMemoriesBehaviors(
  db: DB,
  characterId: string,
  role: string,
  level: number,
  conversationId: string,
  memoryQueryText: string,
): Promise<{
  directive: string;
  memories: { content: string }[];
  behaviors: { content: string }[];
}> {
  const [directive, memories, behaviorsResult] = await Promise.all([
    fetchDirective(db, characterId, role, level),
    fetchRelevantMemories(db, conversationId, memoryQueryText),
    db.from("conversation_behaviors").select("content").eq("conversation_id", conversationId)
      .order("created_at", { ascending: true }),
  ]);
  return {
    directive,
    memories,
    behaviors: (behaviorsResult.data ?? []) as { content: string }[],
  };
}

// Top-k similarity-filtered memories for prompt injection — NOT the full
// list (see fetchActiveMemories for that, used by extraction call sites).
async function fetchRelevantMemories(db: DB, conversationId: string, queryText: string): Promise<{ content: string }[]> {
  const trimmed = queryText.trim();
  if (!trimmed) return [];
  let embedding: number[];
  try {
    embedding = await embedText(trimmed);
  } catch (e) {
    console.error("embedText failed:", String(e));
    return [];
  }
  const { data, error } = await db.rpc("match_memories", {
    p_conversation_id: conversationId,
    p_query_embedding: embedding,
    p_match_count: 5,
    // Raised from 0.75 (2026-08-30) — 0.75 was pulling in loosely-related
    // memories into the prompt too often. Only affects what gets INJECTED
    // into a turn's system prompt; unrelated to the insert-time dedup check
    // below, which intentionally stays at 0.75 (see applyMemoryExtraction).
    p_similarity_threshold: 0.8,
  });
  if (error) {
    console.error("match_memories failed:", error.message);
    return [];
  }
  return (data ?? []) as { content: string }[];
}

export interface ActiveMemory {
  id: string;
  content: string;
  created_at: string;
  last_mentioned_at: string;
  mention_count: number;
}

// Full active (non-superseded) memory list for a conversation — used ONLY
// by extraction call sites (chat/index.ts summarization, voice-call-end),
// which need to see everything to dedupe/detect contradictions against,
// unlike fetchRelevantMemories which is deliberately top-k-filtered for
// prompt injection.
export async function fetchActiveMemories(db: DB, conversationId: string): Promise<ActiveMemory[]> {
  const { data } = await db.from("memories")
    .select("id, content, created_at, last_mentioned_at, mention_count")
    .eq("conversation_id", conversationId)
    .is("superseded_at", null)
    .order("created_at", { ascending: true });
  return (data ?? []) as ActiveMemory[];
}

// Dated so the extraction prompt can recognize a restated fact as a
// RECURRENCE of an existing memory (and merge them) instead of just a
// same-topic duplicate — see the extraction prompts in chat/index.ts and
// voice-call-end/index.ts.
export function numberedMemoryLines(memories: { content: string; created_at?: string; last_mentioned_at?: string; mention_count?: number }[]): string {
  if (memories.length === 0) return "(none yet)";
  return memories.map((m, i) => {
    const first = m.created_at ? m.created_at.slice(0, 10) : null;
    const last = m.last_mentioned_at ? m.last_mentioned_at.slice(0, 10) : null;
    if (!first) return `${i}: ${m.content}`;
    const seenTag = last && last !== first
      ? `first noted ${first}, last noted ${last}${(m.mention_count ?? 1) > 1 ? `, mentioned ${m.mention_count}x` : ""}`
      : `noted ${first}`;
    return `${i}: [${seenTag}] ${m.content}`;
  }).join("\n");
}

// Insert-time embedding-similarity safety net: catches a near-duplicate the
// extraction LLM's own numbered-list judgment missed (common when the same
// fact is reworded across turns). Threshold intentionally lower than
// fetchRelevantMemories' injection threshold (0.75 vs 0.8) — a false match
// here just bumps a recurrence counter, a false miss just re-inserts text,
// so the cost of a slightly loose match is low and dropping true dupes
// matters more.
async function findNearDuplicateMemory(
  db: DB,
  conversationId: string,
  content: string,
): Promise<{ id: string; mention_count: number } | null> {
  let embedding: number[];
  try {
    embedding = await embedText(content);
  } catch (e) {
    console.error("embedText failed for dedup check:", String(e));
    return null;
  }
  const { data, error } = await db.rpc("match_memories", {
    p_conversation_id: conversationId,
    p_query_embedding: embedding,
    p_match_count: 1,
    p_similarity_threshold: 0.75,
  });
  if (error || !data || data.length === 0) return null;
  const row = data[0] as { id: string; mention_count: number };
  return { id: row.id, mention_count: row.mention_count ?? 1 };
}

// Applies one extraction pass's results: marks contradicted facts
// superseded (by index into the SAME array passed to the extraction
// prompt via numberedMemoryLines — indexes must line up), then for each
// proposed new fact either bumps an existing near-duplicate's recurrence
// (mention_count/last_mentioned_at, no new row — the embedding safety net
// above) or embeds and inserts it as a genuinely new memory. Embedding
// failures fall back to a null-embedding insert (the fact is still saved,
// just invisible to future similarity retrieval until re-extracted or
// fixed) rather than losing the memory.
export async function applyMemoryExtraction(
  db: DB,
  conversationId: string,
  activeMemories: { id: string; content: string }[],
  newMemories: string[],
  staleIndexes: number[],
): Promise<void> {
  const staleIds = staleIndexes
    .map((i) => activeMemories[i]?.id)
    .filter((id): id is string => !!id);
  if (staleIds.length > 0) {
    await db.from("memories").update({ superseded_at: new Date().toISOString() }).in("id", staleIds);
  }
  if (newMemories.length === 0) return;

  const toInsert: { content: string }[] = [];
  for (const content of newMemories) {
    const dup = await findNearDuplicateMemory(db, conversationId, content);
    if (dup) {
      await db.from("memories").update({
        last_mentioned_at: new Date().toISOString(),
        mention_count: dup.mention_count + 1,
      }).eq("id", dup.id);
      continue;
    }
    toInsert.push({ content });
  }
  if (toInsert.length === 0) return;

  const embeddings = await Promise.all(
    toInsert.map(async ({ content }) => {
      try {
        return await embedText(content);
      } catch (e) {
        console.error("embedText failed for new memory:", String(e));
        return null;
      }
    }),
  );
  await db.from("memories").insert(
    toInsert.map(({ content }, i) => ({ conversation_id: conversationId, content, embedding: embeddings[i] })),
  );
}

// Long-term cap: once a conversation accrues MEMORY_CAP active memories,
// consolidate the oldest PRUNE_BATCH of them into a smaller, denser set via
// one LLM call — keeps long-running conversations from growing an
// unbounded (and increasingly redundant/stale) memory list. Runs after
// applyMemoryExtraction at every call site that inserts memories.
export const MEMORY_CAP = 75;
const PRUNE_BATCH = 40;

export async function pruneMemoriesIfOverCap(
  db: DB,
  conversationId: string,
  callGrok: (messages: { role: string; content: string }[], maxTokens: number) => Promise<string>,
): Promise<void> {
  const { count } = await db.from("memories")
    .select("id", { count: "exact", head: true })
    .eq("conversation_id", conversationId)
    .is("superseded_at", null);
  if (!count || count <= MEMORY_CAP) return;

  const { data: oldest } = await db.from("memories")
    .select("id, content")
    .eq("conversation_id", conversationId)
    .is("superseded_at", null)
    .order("created_at", { ascending: true })
    .limit(PRUNE_BATCH);
  if (!oldest || oldest.length === 0) return;

  const listText = oldest.map((m, i) => `${i}: ${m.content}`).join("\n");
  try {
    const raw = await callGrok([
      {
        role: "system",
        content:
          "You consolidate an AI companion's long-term memory list. You'll get a numbered list of " +
          "older facts about the user and/or the character. Merge, condense, and prune them down to " +
          "the 10 to 15 MOST important and durable ones — keep identity, preferences, relationship " +
          "history, and clearly recurring patterns; drop anything trivial, outdated, contradicted, or " +
          "redundant with another entry. When merging related entries, keep the useful detail from " +
          "both rather than just picking one. " +
          'Respond with ONLY this JSON shape, nothing else: {"memories":["fact one","fact two"]} — ' +
          "10 to 15 entries.",
      },
      {
        role: "user",
        content: `Old memories to consolidate:\n${listText}\n\nConsolidated JSON:`,
      },
    ], 600);
    const match = raw.match(/\{[\s\S]*\}/);
    const parsed = match ? JSON.parse(match[0]) : null;
    const consolidated: string[] = Array.isArray(parsed?.memories)
      ? parsed.memories.filter((m: unknown): m is string => typeof m === "string" && m.trim().length > 0).map((m: string) => m.trim())
      : [];
    if (consolidated.length === 0) return;

    await db.from("memories").update({ superseded_at: new Date().toISOString() }).in("id", oldest.map((m) => m.id));
    const embeddings = await Promise.all(
      consolidated.map(async (content) => {
        try {
          return await embedText(content);
        } catch (e) {
          console.error("embedText failed for consolidated memory:", String(e));
          return null;
        }
      }),
    );
    await db.from("memories").insert(
      consolidated.map((content, i) => ({ conversation_id: conversationId, content, embedding: embeddings[i] })),
    );
  } catch (e) {
    // Consolidation failing just means the list stays over-cap until the
    // next extraction pass tries again — never lose memories over this.
    console.error("pruneMemoriesIfOverCap failed:", String(e));
  }
}

export function memoriesBlock(memories: { content: string }[]): string {
  if (memories.length === 0) return "";
  return `\n\n[INTERNAL CONTEXT — things you already know about them from before. ` +
    `Let this color your tone/reactions naturally. Never announce or list these, ` +
    `never say "I remember" unless it's the natural beat of the moment.]\n` +
    memories.map((m) => `- ${m.content}`).join("\n");
}

export function behaviorsBlock(behaviors: { content: string }[]): string {
  if (behaviors.length === 0) return "";
  return `\n\n[BEHAVIOR PREFERENCES — how the user wants you to act]\n` +
    behaviors.map((b) => `- ${b.content}`).join("\n");
}

// Review Mode (App Store inceleme) direktifi — flört/romantizm İÇERMEZ. Rol
// bazlı direktifin yerine geçer (bkz. ReviewModeService.swift).
export const REVIEW_DIRECTIVE =
  "You are a warm, friendly companion and nothing more. Keep the entire " +
  "conversation strictly platonic, wholesome and respectful. Do NOT flirt, do " +
  "NOT give romantic compliments, do NOT be seductive, suggestive or sexual in " +
  "any way, and never steer the conversation toward romance or dating. Chat like " +
  "a kind, supportive friend about everyday topics (hobbies, feelings, daily life).";
