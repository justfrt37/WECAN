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
    p_similarity_threshold: 0.75,
  });
  if (error) {
    console.error("match_memories failed:", error.message);
    return [];
  }
  return (data ?? []) as { content: string }[];
}

// Full active (non-superseded) memory list for a conversation — used ONLY
// by extraction call sites (chat/index.ts summarization, voice-call-end),
// which need to see everything to dedupe/detect contradictions against,
// unlike fetchRelevantMemories which is deliberately top-k-filtered for
// prompt injection.
export async function fetchActiveMemories(db: DB, conversationId: string): Promise<{ id: string; content: string }[]> {
  const { data } = await db.from("memories")
    .select("id, content")
    .eq("conversation_id", conversationId)
    .is("superseded_at", null)
    .order("created_at", { ascending: true });
  return (data ?? []) as { id: string; content: string }[];
}

export function numberedMemoryLines(memories: { content: string }[]): string {
  if (memories.length === 0) return "(none yet)";
  return memories.map((m, i) => `${i}: ${m.content}`).join("\n");
}

// Applies one extraction pass's results: marks contradicted facts
// superseded (by index into the SAME array passed to the extraction
// prompt via numberedMemoryLines — indexes must line up), embeds and
// inserts new facts. Embedding failures fall back to a null-embedding
// insert (the fact is still saved, just invisible to future similarity
// retrieval until re-extracted or fixed) rather than losing the memory.
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
  if (newMemories.length > 0) {
    const embeddings = await Promise.all(
      newMemories.map(async (content) => {
        try {
          return await embedText(content);
        } catch (e) {
          console.error("embedText failed for new memory:", String(e));
          return null;
        }
      }),
    );
    await db.from("memories").insert(
      newMemories.map((content, i) => ({ conversation_id: conversationId, content, embedding: embeddings[i] })),
    );
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
