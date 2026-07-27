// supabase/functions/_shared/directiveHelpers.ts
//
// Character directive + memories + behaviors fetch, shared between chat/index.ts
// and voice-call-turn/index.ts — both need the exact same "what does this
// character know and how should it currently behave" assembly.

// Deno-agnostic minimal client type — callers pass their own `db` (createClient
// result) so this module never creates its own connection/env dependency.
type DB = ReturnType<typeof import("https://esm.sh/@supabase/supabase-js@2").createClient>;

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
    directive = script?.directive ?? `İlişki seviyesi ${level}/10. Doğal ve sıcak ol.`;
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
): Promise<{
  directive: string;
  memories: { content: string }[];
  behaviors: { content: string }[];
}> {
  const [directive, memoriesResult, behaviorsResult] = await Promise.all([
    fetchDirective(db, characterId, role, level),
    db.from("memories").select("content").eq("conversation_id", conversationId)
      .order("created_at", { ascending: true }),
    db.from("conversation_behaviors").select("content").eq("conversation_id", conversationId)
      .order("created_at", { ascending: true }),
  ]);
  return {
    directive,
    memories: (memoriesResult.data ?? []) as { content: string }[],
    behaviors: (behaviorsResult.data ?? []) as { content: string }[],
  };
}

export function memoriesBlock(memories: { content: string }[]): string {
  if (memories.length === 0) return "";
  return `\n\n[MEMORIES — facts to remember about the user/relationship]\n` +
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
