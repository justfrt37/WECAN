// supabase/functions/voice-call-end/index.ts
//
// Ends a call: one-time charge (elapsedSeconds * 3 tokens), marks the
// session ended, and runs one-shot memory extraction over the full
// call_turns transcript — same JSON-extraction pattern chat/index.ts's
// periodic summarization uses — appending any new durable facts to the
// character's existing `memories` (bkz. design spec, chat/index.ts's
// "newMemories" summarization block).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { fetchActiveMemories, numberedMemoryLines, applyMemoryExtraction, pruneMemoriesIfOverCap } from "../_shared/directiveHelpers.ts";
import type { NewMemory } from "../_shared/directiveHelpers.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

import { callLLM } from "../_shared/llm.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

const TOKENS_PER_SECOND = 3;

function userIdFromJWT(authHeader: string | null): string | null {
  if (!authHeader?.startsWith("Bearer ")) return null;
  const token = authHeader.slice(7);
  const parts = token.split(".");
  if (parts.length < 2) return null;
  try {
    let b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    while (b64.length % 4) b64 += "=";
    return JSON.parse(atob(b64)).sub ?? null;
  } catch {
    return null;
  }
}

function extractJson(raw: string): any | null {
  const match = raw.match(/\{[\s\S]*\}/);
  if (!match) return null;
  try { return JSON.parse(match[0]); } catch { return null; }
}

function callText(messages: { role: string; content: string }[], maxTokens: number): Promise<string> {
  return callLLM(messages, { maxTokens, temperature: 0.7 });
}

async function extractAndStoreMemories(conversationId: string, callSessionId: string) {
  const { data: turns } = await db.from("call_turns")
    .select("role, content").eq("call_session_id", callSessionId).order("seq", { ascending: true });
  if (!turns || turns.length === 0) return;

  const activeMemories = await fetchActiveMemories(db, conversationId);
  const existingMemoryLines = numberedMemoryLines(activeMemories);

  const transcript = turns.map((t) => `${t.role === "user" ? "User" : "You"}: ${t.content}`).join("\n");

  const raw = await callText([
    {
      role: "system",
      content:
        "Extract NEW durable facts worth permanently remembering from this voice call transcript, that are " +
        "NOT already covered by the existing memories list you'll be given (numbered, one per line, each " +
        "tagged with when it was first/last noted). Favor identity, personality, and life facts — who " +
        "someone IS (job, living situation, relationships, values, recurring habits, how they tend to feel " +
        "or act) — over one-off day-to-day small talk that has no lasting relevance. This isn't a strict " +
        "filter: a passing detail is still worth keeping if it's the kind of thing that should color how " +
        "the character responds days later. If there's nothing worth keeping, return an empty array. " +
        "Include BOTH sides:\n" +
        "- USER facts: name, preferences, promises, key relationship moments, recurring patterns.\n" +
        "- CHARACTER facts: things the character herself established/committed to on this call — a pet " +
        "name she used, a boundary she set, a backstory detail she improvised that should stay consistent, " +
        "a promise she made. These matter just as much as the user's.\n\n" +
        "RECURRENCE: if the new content restates or reinforces something an existing memory already says " +
        "(even worded differently), do NOT add it as a separate new memory. Instead put a single MERGED " +
        "replacement fact in newMemories that folds in the recurrence as an observed pattern (naming both " +
        "dates), and put that existing memory's number in staleIndexes so the old single-instance version " +
        "gets replaced by the merged one.\n\n" +
        "ALSO identify any existing memories (by their number) that this transcript now CONTRADICTS — e.g. " +
        "the user previously said they're a barista and now say they just started a nursing job. Return " +
        "those numbers in staleIndexes. If nothing is contradicted, return an empty array.\n\n" +
        // is_pinned 2026-09-02'de eklendi ve chat/index.ts'in fold prompt'unda
        // zaten vardı; burada yoktu, yani sesli aramadan çıkan hiçbir kimlik
        // bilgisi pinlenmiyordu ve zamanla budanabiliyordu. Metin sohbetiyle
        // aynı ölçüt kullanılıyor ki iki yol aynı hafızayı aynı şekilde doldursun.
        "PINNING: mark each new memory with \"pinned\": true ONLY if it is an identity-level fact " +
        "that should survive forever — the user's name, age, city, job, family members, pets, " +
        "birthday, allergies or medical constraints, and the equivalent permanent facts the " +
        "character has established about herself (the pet name she calls the user, a core " +
        "backstory commitment). Everything softer — a passing mood, a plan for this week, a " +
        "one-off preference — is \"pinned\": false. Pinned memories are never compressed away, so " +
        "be strict: if you'd still want it known a year from now, pin it; otherwise don't.\n\n" +
        'Respond with ONLY this JSON shape, nothing else: {"newMemories":' +
        '[{"content":"fact one","pinned":true},{"content":"fact two","pinned":false}],' +
        '"staleIndexes":[0,2]}',
    },
    {
      role: "user",
      content: `Existing memories (numbered — do not repeat these, but flag contradicted ones in staleIndexes):\n${existingMemoryLines}\n\nCall transcript:\n${transcript}\n\nJSON:`,
    },
  ], 500);

  const parsed = extractJson(raw);
  // Her iki şekli de kabul ediyor: prompt'un istediği {content, pinned}
  // nesneleri ve model eski biçime dönerse düz string — string düşürülmüyor,
  // sadece pinlenmemiş sayılıyor. chat/index.ts ile birebir aynı davranış.
  const newMemories: NewMemory[] = Array.isArray(parsed?.newMemories)
    ? parsed.newMemories
        .map((m: unknown): NewMemory | null => {
          if (typeof m === "string") {
            return m.trim() ? { content: m.trim(), pinned: false } : null;
          }
          if (m && typeof m === "object") {
            const content = (m as Record<string, unknown>).content;
            if (typeof content === "string" && content.trim()) {
              return { content: content.trim(), pinned: (m as Record<string, unknown>).pinned === true };
            }
          }
          return null;
        })
        .filter((m: NewMemory | null): m is NewMemory => m !== null)
    : [];
  const staleIndexes: number[] = Array.isArray(parsed?.staleIndexes)
    ? parsed.staleIndexes.filter((i: unknown): i is number => typeof i === "number" && Number.isInteger(i))
    : [];
  await applyMemoryExtraction(db, conversationId, activeMemories, newMemories, staleIndexes);
  await pruneMemoriesIfOverCap(db, conversationId, callText);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);

    const body = await req.json();
    const callSessionId: string = body.callSessionId;
    const actualElapsedSeconds: number = Number(body.actualElapsedSeconds) || 0;
    if (!callSessionId) return json({ error: "callSessionId required" }, 400);

    const { data: session } = await db.from("call_sessions")
      .select("id, user_id, conversation_id, status").eq("id", callSessionId).maybeSingle();
    if (!session || session.user_id !== uid) return json({ error: "invalid_call_session" }, 400);

    // ATOMICALLY claim the end. The client can fire voice-call-end more than
    // once for the same session (hang-up button + SDK disconnect handler + view
    // teardown all racing), and the old "select status, if ended bail, else
    // charge, then set ended" was a check-then-act race — three concurrent
    // requests all saw status "active" and all called charge_tokens, so a
    // single 2-minute call was billed ~3x (bkz. kullanıcı raporu / token_
    // transactions: three "voice" charges ~380 each within 2 seconds).
    // Only the request that actually flips active -> ended may charge.
    const { data: claimed } = await db.from("call_sessions")
      .update({ status: "ended", ended_at: new Date().toISOString() })
      .eq("id", callSessionId)
      .eq("status", "active")
      .select("id");

    if (!claimed || claimed.length === 0) {
      const { data: balanceRow } = await db.from("token_balances").select("balance").eq("user_id", uid).maybeSingle();
      return json({ tokensCharged: 0, newBalance: balanceRow?.balance ?? 0 });
    }

    const tokensCharged = Math.round(actualElapsedSeconds * TOKENS_PER_SECOND);
    let newBalance = 0;
    if (tokensCharged > 0) {
      await db.rpc("charge_tokens", { p_user_id: uid, p_amount: tokensCharged, p_reason: "voice" });
    }
    const { data: balanceRow } = await db.from("token_balances").select("balance").eq("user_id", uid).maybeSingle();
    newBalance = balanceRow?.balance ?? 0;

    await db.from("call_sessions")
      .update({ tokens_charged: tokensCharged })
      .eq("id", callSessionId);

    if (session.conversation_id) {
      try {
        await extractAndStoreMemories(session.conversation_id, callSessionId);
      } catch (e) {
        console.error("memory extraction failed:", String(e));
      }
    }

    return json({ tokensCharged, newBalance });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
