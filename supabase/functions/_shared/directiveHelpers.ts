// supabase/functions/_shared/directiveHelpers.ts
//
// Character directive + memories + behaviors fetch, shared between chat/index.ts
// and voice-call-turn/index.ts — both need the exact same "what does this
// character know and how should it currently behave" assembly.

// The type arguments matter. Without them createClient infers Database=unknown,
// which collapses every table and RPC to `never` — so `deno check` reported 19
// errors on this codebase (identical count on v107, i.e. this predates the
// 2026-09-02 refactor) and, worse, TypeScript silently provided ZERO safety on
// any .from()/.rpc()/.insert() call. Supabase Edge Functions only transpile at
// deploy time, so it never surfaced. Naming the schema restores real checking.
// deno-lint-ignore no-explicit-any
type DB = ReturnType<typeof import("https://esm.sh/@supabase/supabase-js@2").createClient<any, "public", any>>;

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

// Hybrid retrieval (2026-09-02). Replaces a pure-dense match_memories() call
// that gated on cosine >= 0.8 and returned at most 5 rows. That threshold was
// the cause of a confirmed live failure: generic questions ("what do you
// remember about me") cleared nothing and returned ZERO memories, so the
// character insisted the user had never told her facts that were sitting in
// the table. Memories are very short atomic facts, which is exactly where
// dense embeddings are weakest and exact term matching is strongest.
//
// match_memories_hybrid fuses three ranked lists with RRF — dense (pgvector),
// lexical (Postgres FTS, catches proper nouns like Zeytin/Bursa/Can across
// the TR-query/EN-memory language gap), and a lightly-weighted recency list.
// There is no threshold anywhere, so "matched nothing" cannot happen again;
// the recency arm also guarantees a non-empty result whenever the
// conversation has any memories at all.
//
// Deliberately NOT returning [] when embedding fails or query text is empty:
// the other two arms still produce a useful result on their own.
const MEMORY_MATCH_COUNT = 8;

async function fetchRelevantMemories(db: DB, conversationId: string, queryText: string): Promise<{ content: string }[]> {
  const trimmed = queryText.trim();
  let embedding: number[] | null = null;
  if (trimmed) {
    try {
      embedding = await embedText(trimmed);
    } catch (e) {
      console.error("embedText failed (falling back to lexical+recency):", String(e));
    }
  }
  const { data, error } = await db.rpc("match_memories_hybrid", {
    p_conversation_id: conversationId,
    p_query_embedding: embedding,
    p_query_text: trimmed,
    p_match_count: MEMORY_MATCH_COUNT,
  });
  if (error) {
    console.error("match_memories_hybrid failed:", error.message);
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

export async function fetchActiveMemories(db: DB, conversationId: string): Promise<ActiveMemory[]> {
  const { data } = await db.from("memories")
    .select("id, content, created_at, last_mentioned_at, mention_count")
    .eq("conversation_id", conversationId)
    .is("superseded_at", null)
    .order("created_at", { ascending: true });
  return (data ?? []) as ActiveMemory[];
}

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

export interface NewMemory {
  content: string;
  /**
   * Identity-level facts (name, age, city, job, family, pets, birthday,
   * allergies, core boundaries). Pinned rows are excluded from pruning
   * UNCONDITIONALLY and get a retrieval boost — see select_prune_candidates
   * and the pinned arm of match_memories_hybrid.
   *
   * This exists because the pruning value score is built on reinforcement and
   * recency, and identity facts are pathologically bad on both: you state your
   * name once and never repeat it, so three months later "User's name is Mert"
   * scores near zero while "went to the gym yesterday" scores near the top.
   * No heuristic over mention_count/last_mentioned_at can fix that — it needs
   * an explicit flag set at extraction time.
   */
  pinned: boolean;
}

export async function applyMemoryExtraction(
  db: DB,
  conversationId: string,
  activeMemories: { id: string; content: string }[],
  newMemories: NewMemory[],
  staleIndexes: number[],
): Promise<void> {
  const staleIds = staleIndexes
    .map((i) => activeMemories[i]?.id)
    .filter((id): id is string => !!id);
  if (staleIds.length > 0) {
    await db.from("memories").update({ superseded_at: new Date().toISOString() }).in("id", staleIds);
  }
  if (newMemories.length === 0) return;

  // findNearDuplicateMemory only sees rows already IN the table, so two
  // identical facts arriving in the SAME extraction batch both missed it and
  // both got inserted — confirmed live, "Character prefers herbal tea over
  // coffee" exists twice, written 11 seconds apart. `seen` closes that gap by
  // also deduping within the batch before anything is written.
  const toInsert: NewMemory[] = [];
  const seen = new Set<string>();
  for (const mem of newMemories) {
    const key = mem.content.trim().toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    const dup = await findNearDuplicateMemory(db, conversationId, mem.content);
    if (dup) {
      // Restating a fact is also evidence it's durable, so a recurrence can
      // promote an existing row to pinned — but never demote one.
      const update: Record<string, unknown> = {
        last_mentioned_at: new Date().toISOString(),
        mention_count: dup.mention_count + 1,
      };
      if (mem.pinned) update.is_pinned = true;
      await db.from("memories").update(update).eq("id", dup.id);
      continue;
    }
    toInsert.push(mem);
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
    toInsert.map(({ content, pinned }, i) => ({
      conversation_id: conversationId,
      content,
      embedding: embeddings[i],
      is_pinned: pinned,
    })),
  );
}

export const MEMORY_CAP = 75;
// Was 40 consolidated down to 10-15 — a ~3.3x squeeze per cycle. Since each
// cycle re-compresses text that may already be the output of a previous
// consolidation, an aggressive ratio degrades old history fast (the same
// repeated-compression decay that killed the old free-text summary system).
// 30 -> 15-20 is a ~1.7x squeeze: it fires more often but loses far less each
// time, and now operates on the LEAST valuable rows rather than the oldest.
const PRUNE_BATCH = 30;
// If protection leaves fewer than this eligible, consolidating isn't worth an
// LLM call — skip and let rows age into eligibility next cycle.
const MIN_PRUNE_BATCH = 12;
// Only if a conversation blows past 2x the cap do we override protection.
// Normally unreachable: protection needs a mention within 14 days, and
// last_mentioned_at is only bumped when a fact actually RECURS (see
// applyMemoryExtraction), not when a memory is merely retrieved.
const HARD_CEILING = MEMORY_CAP * 2;
// Superseded rows are invisible to retrieval but were never deleted, so they
// accumulated forever. Keep a window for debugging, then drop them.
const SUPERSEDED_RETENTION_DAYS = 90;

export async function pruneMemoriesIfOverCap(
  db: DB,
  conversationId: string,
  callGrok: (messages: { role: string; content: string }[], maxTokens: number) => Promise<string>,
): Promise<void> {
  const cutoff = new Date(Date.now() - SUPERSEDED_RETENTION_DAYS * 86400_000).toISOString();
  const { error: cleanupError } = await db.from("memories")
    .delete()
    .eq("conversation_id", conversationId)
    .not("superseded_at", "is", null)
    .lt("superseded_at", cutoff);
  if (cleanupError) console.error("superseded cleanup failed:", cleanupError.message);

  const { count } = await db.from("memories")
    .select("id", { count: "exact", head: true })
    .eq("conversation_id", conversationId)
    .is("superseded_at", null);
  if (!count || count <= MEMORY_CAP) return;

  // Value-ranked, protection-aware candidates (see select_prune_candidates).
  const { data: normal, error: candErr } = await db.rpc("select_prune_candidates", {
    p_conversation_id: conversationId,
    p_limit: PRUNE_BATCH,
  });
  if (candErr) {
    console.error("select_prune_candidates failed:", candErr.message);
    return;
  }
  let candidates = (normal ?? []) as { id: string; content: string }[];

  if (candidates.length < MIN_PRUNE_BATCH) {
    if (count <= HARD_CEILING) {
      console.log(`prune skipped: only ${candidates.length} eligible of ${count} active`);
      return;
    }
    const { data: forced } = await db.rpc("select_prune_candidates", {
      p_conversation_id: conversationId,
      p_limit: PRUNE_BATCH,
      p_ignore_protection: true,
    });
    candidates = (forced ?? []) as { id: string; content: string }[];
    console.log(`prune forced past hard ceiling: ${count} active, ${candidates.length} candidates`);
  }
  if (candidates.length === 0) return;

  const listText = candidates.map((m, i) => `${i}: ${m.content}`).join("\n");
  try {
    const raw = await callGrok([
      {
        role: "system",
        content:
          "You consolidate an AI companion's long-term memory list. You'll get a numbered list of " +
          "memories that scored LOWEST on durability — rarely reinforced and not mentioned in a " +
          "while — so they're the best candidates for compression. Merge, condense, and prune them " +
          "down to 15 to 20 entries. Keep identity, preferences, relationship history, and clearly " +
          "recurring patterns; drop anything trivial, outdated, contradicted, or redundant with " +
          "another entry. When merging related entries, keep the useful detail from both rather than " +
          "just picking one. Critically: never drop a concrete identifying detail (a name, place, " +
          "job, relationship, date, allergy) just because the line it sits in looks unimportant — " +
          "carry it into the merged entry. " +
          'Respond with ONLY this JSON shape, nothing else: {"memories":["fact one","fact two"]} — ' +
          "15 to 20 entries.",
      },
      {
        role: "user",
        content: `Memories to consolidate:\n${listText}\n\nConsolidated JSON:`,
      },
    ], 800);
    const match = raw.match(/\{[\s\S]*\}/);
    const parsed = match ? JSON.parse(match[0]) : null;
    const consolidated: string[] = Array.isArray(parsed?.memories)
      ? parsed.memories.filter((m: unknown): m is string => typeof m === "string" && m.trim().length > 0).map((m: string) => m.trim())
      : [];
    if (consolidated.length === 0) return;

    await db.from("memories").update({ superseded_at: new Date().toISOString() }).in("id", candidates.map((m) => m.id));
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

export const REVIEW_DIRECTIVE =
  "You are a warm, friendly companion and nothing more. Keep the entire " +
  "conversation strictly platonic, wholesome and respectful. Do NOT flirt, do " +
  "NOT give romantic compliments, do NOT be seductive, suggestive or sexual in " +
  "any way, and never steer the conversation toward romance or dating. Chat like " +
  "a kind, supportive friend about everyday topics (hobbies, feelings, daily life).";
