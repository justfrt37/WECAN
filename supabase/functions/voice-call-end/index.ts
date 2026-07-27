// supabase/functions/voice-call-end/index.ts
//
// Ends a call: one-time charge (elapsedSeconds * 3 tokens), marks the
// session ended, and runs one-shot memory extraction over the full
// call_turns transcript — same JSON-extraction pattern chat/index.ts's
// periodic summarization uses — appending any new durable facts to the
// character's existing `memories` (bkz. design spec, chat/index.ts's
// "newMemories" summarization block).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const XAI_API_KEY = Deno.env.get("XAI_API_KEY") ?? "";
const XAI_URL = "https://api.x.ai/v1/chat/completions";
const MODEL = "grok-4-1-fast-non-reasoning";

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

async function callGrok(messages: { role: string; content: string }[], maxTokens: number): Promise<string> {
  const resp = await fetch(XAI_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${XAI_API_KEY}` },
    body: JSON.stringify({ model: MODEL, messages, temperature: 0.7, max_tokens: maxTokens }),
  });
  if (!resp.ok) throw new Error(`LLM ${resp.status}: ${await resp.text()}`);
  const data = await resp.json();
  return data?.choices?.[0]?.message?.content ?? "";
}

async function extractAndStoreMemories(conversationId: string, callSessionId: string) {
  const { data: turns } = await db.from("call_turns")
    .select("role, content").eq("call_session_id", callSessionId).order("created_at", { ascending: true });
  if (!turns || turns.length === 0) return;

  const { data: existingMemories } = await db.from("memories")
    .select("content").eq("conversation_id", conversationId).order("created_at", { ascending: true });
  const existingMemoryLines = (existingMemories ?? []).map((m) => `- ${m.content}`).join("\n") || "(none yet)";

  const transcript = turns.map((t) => `${t.role === "user" ? "User" : "You"}: ${t.content}`).join("\n");

  const raw = await callGrok([
    {
      role: "system",
      content:
        "Extract NEW durable atomic facts worth permanently remembering (name, preferences, " +
        "promises, key relationship moments) from this voice call transcript, that are NOT " +
        "already covered by the existing memories list you'll be given — do not repeat anything " +
        "already in that list, even reworded. If there's nothing new, return an empty array. " +
        'Respond with ONLY this JSON shape, nothing else: {"newMemories":["fact one","fact two"]}',
    },
    {
      role: "user",
      content: `Existing memories (do not repeat these):\n${existingMemoryLines}\n\nCall transcript:\n${transcript}\n\nJSON:`,
    },
  ], 500);

  const parsed = extractJson(raw);
  const newMemories: string[] = Array.isArray(parsed?.newMemories)
    ? parsed.newMemories.filter((m: unknown): m is string => typeof m === "string" && m.trim().length > 0)
    : [];
  if (newMemories.length > 0) {
    await db.from("memories").insert(
      newMemories.map((content) => ({ conversation_id: conversationId, content: content.trim() })),
    );
  }
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
    if (session.status === "ended") {
      const { data: balanceRow } = await db.from("token_balances").select("balance").eq("user_id", uid).maybeSingle();
      return json({ tokensCharged: 0, newBalance: balanceRow?.balance ?? 0 });
    }

    const tokensCharged = Math.round(actualElapsedSeconds * TOKENS_PER_SECOND);
    let newBalance = 0;
    if (tokensCharged > 0) {
      await db.rpc("charge_tokens", { p_user_id: uid, p_amount: tokensCharged, p_reason: "voice_call" });
    }
    const { data: balanceRow } = await db.from("token_balances").select("balance").eq("user_id", uid).maybeSingle();
    newBalance = balanceRow?.balance ?? 0;

    await db.from("call_sessions")
      .update({ status: "ended", ended_at: new Date().toISOString(), tokens_charged: tokensCharged })
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
