// supabase/functions/voice-call-start/index.ts
//
// Starts a real-time voice call session against an ElevenLabs Agent.
// Finalizes any orphaned `active` session for this user first (crash
// recovery — see voice-call-end for the shared finalize logic), pre-checks
// balance, builds the FULL system prompt ONCE here (memories/behaviors don't
// change mid-call, so unlike the old per-turn voice-call-turn this is never
// re-fetched per turn — see
// docs/superpowers/specs/2026-07-29-voice-call-agents-migration-design.md),
// resolves the character's voice/stability, and fetches a short-lived
// ElevenLabs conversation token so the ElevenLabs API key never reaches the
// client.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  fetchDirectiveMemoriesBehaviors, memoriesBlock, behaviorsBlock, REVIEW_DIRECTIVE,
} from "../_shared/directiveHelpers.ts";
import { elevenVoiceIdFor } from "../_shared/elevenVoiceMap.ts";
import { callVoiceSettingsFor } from "../_shared/elevenVoiceSettings.ts";
import { requireVoiceEntitlement } from "../_shared/entitlements.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

const XAI_API_KEY = Deno.env.get("XAI_API_KEY") ?? "";
const XAI_URL = "https://api.x.ai/v1/chat/completions";
const MODEL = "grok-4.3";

const ELEVENLABS_API_KEY = Deno.env.get("ELEVEN_LABS") ?? "";
// TEMP: hardcoded instead of the ELEVENLABS_AGENT_ID secret — CLI account
// isn't an org Owner so `supabase secrets set` is blocked. Move back to
// Deno.env.get("ELEVENLABS_AGENT_ID") once secret write access is sorted.
const ELEVENLABS_AGENT_ID = Deno.env.get("ELEVENLABS_AGENT_ID") ?? "agent_5701kyp1mydkfqnsfn9zw0c2jbqn";

const TOKENS_PER_SECOND = 3;
const MIN_START_BALANCE = 30; // ~10s of call time

// Replaces the old VOICE_TAGS_RULE — Flash v2.5 doesn't support [bracket]
// audio tags, so emotion has to come through word choice/punctuation instead.
// ISO 639-1 code -> display name, matching Plumm/Services/ConversationLanguage.swift's
// `supported` set exactly (tr/en/de/es/fr/it/pt) — client detects the code
// from chat history (or device locale if the chat is empty) and sends it here.
const LANGUAGE_NAMES: Record<string, string> = {
  tr: "Turkish", en: "English", de: "German", es: "Spanish", fr: "French", it: "Italian", pt: "Portuguese",
};

function languageRule(code: string): string {
  const name = LANGUAGE_NAMES[code];
  if (!name) return "";
  return (
    `\n\nLANGUAGE RULE: This call is in ${name} — this was determined from the user's ` +
    "own chat history, not a guess. Speak ONLY in it, never mix in another language, " +
    "never comment on the language itself. Sound like a real person on a phone call " +
    "in that language — warm, colloquial, never robotic."
  );
}

// Emotion/pacing guidance for the voice-call model, in English (the model
// output itself is spoken through ElevenLabs Flash v2.5, which does not
// support [bracket] audio tags, so emotion has to land through word choice
// and punctuation instead of stage directions).
const VOICE_CALL_STYLE_RULE =
  "\n\nVOICE STYLE RULE: This reply will be SPOKEN aloud in a real-time phone call " +
  "(ElevenLabs Flash model, no [bracket] tag support). Convey emotion through word choice " +
  "and punctuation, not tags: an exclamation mark for excitement, an ellipsis (...) for " +
  "hesitation, sentence structure for emphasis. Keep sentences short and natural — this is " +
  "a phone call, not a monologue: 1-2 sentences per reply (rarely 3), the way a real person " +
  "actually talks on the phone. NEVER open with a laugh sound like 'haha', 'hehe', 'ahah' — " +
  "almost nobody opens a sentence laughing on an actual phone call. Lead with what you're " +
  "actually saying; if a laugh/giggle genuinely fits, tuck it INSIDE or at the END of the " +
  "sentence, never as the opening word.";

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

// Charges for an orphaned/crashed session using its last checkpoint, marks
// it ended. Unchanged from the pre-migration voice-call-start.
async function finalizeOrphaned(uid: string) {
  const { data: orphans } = await db
    .from("call_sessions")
    .select("id, last_checkpoint_seconds")
    .eq("user_id", uid)
    .eq("status", "active");
  if (!orphans || orphans.length === 0) return;
  for (const session of orphans) {
    const tokens = Math.round((session.last_checkpoint_seconds ?? 0) * TOKENS_PER_SECOND);
    if (tokens > 0) {
      await db.rpc("charge_tokens", { p_user_id: uid, p_amount: tokens, p_reason: "voice" });
    }
    await db.from("call_sessions")
      .update({ status: "ended", ended_at: new Date().toISOString(), tokens_charged: tokens })
      .eq("id", session.id);
  }
}

// Opener instruction is built here (not baked into the persistent
// systemPrompt) so it only costs tokens on this one-off first-message call,
// not on every turn for the rest of the call. Deliberately gives BEHAVIOR
// to follow, never example lines to recite — a scripted example in the
// prompt gets echoed near-verbatim turn after turn (see chat/index.ts's
// same lesson re: opener habits).
function openerInstruction(recentChatGapMinutes: number | null): string {
  if (recentChatGapMinutes !== null && recentChatGapMinutes <= 10) {
    return (
      `The user was just texting you ${Math.max(1, Math.round(recentChatGapMinutes))} minute(s) ago — this ` +
      "call is a direct continuation of that conversation, not a cold start. Texting-to-calling is a bigger " +
      "conversational moment than another text (more intimate, more immediate) — your opener should register " +
      "that shift, and carry over whatever mood/energy that recent chat was actually in (playful, needy, " +
      "annoyed, sweet, whatever it was) rather than resetting to a generic greeting."
    );
  }
  return (
    "There's no recent chat to continue from — this is a cold call open, like actually picking up the " +
    "phone without knowing exactly what mood you're about to be in. React the way a real person genuinely " +
    "into the caller would when the phone rings/connects — a beat of surprise, warmth, maybe playful or " +
    "teasing depending on your personality — never a flat scripted greeting. Vary the reaction every time, " +
    "never settle into a fixed opening line."
  );
}

// Generates the greeting the Agent speaks first, in-character — uses the
// same system prompt so it matches personality/relationship level. Falls
// back to a plain greeting if Grok fails, since a missing first message
// isn't worth failing the whole call start over.
async function generateFirstMessage(systemPrompt: string, recentChatGapMinutes: number | null): Promise<string> {
  const fallback = "Hey!";
  try {
    const resp = await fetch(XAI_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${XAI_API_KEY}` },
      body: JSON.stringify({
        model: MODEL,
        messages: [
          { role: "system", content: systemPrompt },
          {
            role: "user",
            content: `[The call just connected. ${openerInstruction(recentChatGapMinutes)} Say a short, ` +
              "natural opening line — 1 sentence, in character. Nothing else, no explanation.]",
          },
        ],
        temperature: 0.9,
        max_tokens: 40,
      }),
    });
    if (!resp.ok) return fallback;
    const data = await resp.json();
    const text = (data?.choices?.[0]?.message?.content ?? "").trim();
    return text || fallback;
  } catch {
    return fallback;
  }
}

async function fetchConversationToken(): Promise<{ token: string; conversationId: string }> {
  const url = `https://api.elevenlabs.io/v1/convai/conversation/token?agent_id=${ELEVENLABS_AGENT_ID}`;
  const resp = await fetch(url, { headers: { "xi-api-key": ELEVENLABS_API_KEY } });
  if (!resp.ok) throw new Error(`ElevenLabs token fetch ${resp.status}: ${await resp.text()}`);
  const data = await resp.json();
  return { token: data.token, conversationId: data.conversation_id };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);

    // Sesli arama Pro+ / Pro Max hakkı (bkz. _shared/entitlements.ts) — Pro'da
    // yok. Oturum açılmadan ve jeton düşülmeden ÖNCE kontrol edilir.
    const voiceGate = await requireVoiceEntitlement(db, uid);
    if (voiceGate) return json(voiceGate.body, voiceGate.status);

    const body = await req.json();
    const characterId: string = body.characterId;
    const reviewMode: boolean = body.reviewMode === true;
    const language: string = body.language ?? "en";
    if (!characterId) return json({ error: "characterId required" }, 400);
    if (!ELEVENLABS_AGENT_ID) return json({ error: "ELEVENLABS_AGENT_ID not configured" }, 500);

    await finalizeOrphaned(uid);

    const { data: balanceRow } = await db.from("token_balances").select("balance").eq("user_id", uid).maybeSingle();
    if ((balanceRow?.balance ?? 0) < MIN_START_BALANCE) {
      return json({ error: "insufficient_tokens" }, 402);
    }

    // `vibe` yaşamıyor characters'ta bir sütun olarak — builder_selections
    // jsonb'sinin içinde. Eskiden yanlışlıkla düz sütun gibi seçilmeye
    // çalışılıyordu (`vibe` mevcut değil hatası) — sorgu HER SEFERİNDE
    // patlıyor, `character` hep null kalıyor, herkes aynı varsayılan
    // (flirty/Sweet) sese düşüyordu (bkz. kullanıcı raporu — "tüm botlar
    // aynı sesi kullanıyor").
    const { data: character } = await db.from("characters")
      .select("personality_role, voice_id, builder_selections").eq("id", characterId).maybeSingle();
    const personalityRole: string = character?.personality_role ?? "flirty";
    const vibe: string = (character?.builder_selections as { vibe?: string } | null)?.vibe ?? "Sweet";

    // Konuşmayı bul ya da oluştur (kullanıcı + karakter) — chat/index.ts'nin
    // AYNI deseni. Client bir conversationId'yi ASLA takip etmiyor (chat
    // tarafında da bu id sunucu tarafında (uid, characterId)'den çözülüyor,
    // istemciye kalıcı bir state olarak hiç dönmüyor) — önceden body'den
    // client-supplied conversationId bekleniyordu, bu YAPISAL olarak hep
    // undefined geliyordu ve call_sessions.conversation_id %100 null
    // kalıyordu (bkz. kullanıcı raporu — sesli arama tabloları conversation
    // ile eşleşmiyor). En güncel olanı al — dupe'lar varsa maybeSingle patlar.
    const { data: convoRows } = await db
      .from("conversations")
      .select("id")
      .eq("user_id", uid)
      .eq("character_id", characterId)
      .order("updated_at", { ascending: false })
      .limit(1);
    let convo = convoRows?.[0];
    if (!convo) {
      const ins = await db.from("conversations").insert({ user_id: uid, character_id: characterId }).select("id").single();
      convo = ins.data!;
    }
    const conversationId: string = convo.id;

    // Retrieval query text — last 3 prior chat messages for this
    // conversation (a call has no turns of its own yet at start time; the
    // conversation's `messages` table, shared with chat/index.ts, is the
    // only source of "what's currently being discussed"). No prior
    // messages (brand new conversation) → empty string →
    // fetchDirectiveMemoriesBehaviors skips retrieval, no memories block.
    const { data: recentForQuery } = await db
      .from("messages")
      .select("content, created_at")
      .eq("conversation_id", conversationId)
      .order("created_at", { ascending: false })
      .limit(3);
    const memoryQueryText = (recentForQuery ?? []).map((m) => m.content).reverse().join(" ").trim();
    // Recency of the last chat message — feeds the opener instruction
    // (texting-to-calling continuation vs. genuine cold open, see
    // openerInstruction below).
    const recentChatGapMinutes = recentForQuery?.[0]?.created_at
      ? (Date.now() - new Date(recentForQuery[0].created_at).getTime()) / 60_000
      : null;

    const { directive: fetchedDirective, memories, behaviors } =
      await fetchDirectiveMemoriesBehaviors(db, characterId, personalityRole, 1, conversationId, memoryQueryText);
    const directive = reviewMode ? REVIEW_DIRECTIVE : fetchedDirective;
    let systemPrompt = directive;
    systemPrompt += memoriesBlock(memories);
    systemPrompt += behaviorsBlock(behaviors);
    systemPrompt += VOICE_CALL_STYLE_RULE;
    systemPrompt += languageRule(language);

    const voiceId = character?.voice_id || elevenVoiceIdFor(personalityRole, vibe, characterId);
    const { stability, speed } = callVoiceSettingsFor(personalityRole);
    const firstMessage = await generateFirstMessage(systemPrompt, recentChatGapMinutes);

    const { data: session, error } = await db.from("call_sessions").insert({
      user_id: uid,
      character_id: characterId,
      conversation_id: conversationId,
      status: "active",
    }).select("id").single();
    if (error || !session) return json({ error: String(error) }, 500);

    let conversationToken: string;
    try {
      const tokenResult = await fetchConversationToken();
      conversationToken = tokenResult.token;
    } catch (e) {
      // Roll back — no point leaving an active call_sessions row for a call
      // that never actually got an ElevenLabs token to connect with.
      await db.from("call_sessions")
        .update({ status: "ended", ended_at: new Date().toISOString(), tokens_charged: 0 })
        .eq("id", session.id);
      return json({ error: `elevenlabs_token_failed: ${String(e)}` }, 502);
    }

    return json({
      callSessionId: session.id,
      conversationToken,
      systemPrompt,
      voiceId,
      stability,
      speed,
      firstMessage,
    });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
