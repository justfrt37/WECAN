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
import { stabilityFor } from "../_shared/elevenVoiceSettings.ts";
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
const MODEL = "grok-4-1-fast-non-reasoning";

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

const VOICE_CALL_STYLE_RULE =
  "\n\nSES TARZI KURALI: Bu cevap gerçek zamanlı bir telefon görüşmesinde SESLENDİRİLECEK " +
  "(ElevenLabs Flash modeli, köşeli parantez etiketleri DESTEKLENMİYOR). Duyguyu etiketlerle " +
  "değil kelime seçimi ve noktalamayla ver: heyecanı ünlem işaretiyle, tereddüdü üç nokta (...) " +
  "ile, vurguyu cümle yapısıyla göster. Kısa, doğal cümleler kur — bu bir telefon görüşmesi, " +
  "monolog değil: cevabın 1-2 cümle olsun (nadiren 3), gerçek bir insanın telefonda konuştuğu gibi. " +
  "ASLA 'haha', 'hehe', 'ahah' gibi bir gülme sesiyle BAŞLAMA — gerçek bir telefon konuşmasında " +
  "neredeyse kimse cümlesine gülerek başlamaz. Doğrudan söyleyeceğin şeyle aç; gülme/kikirdeme " +
  "gerçekten komikse cümlenin İÇİNE ya da SONUNA serpiştir, açılış kelimesi olarak değil.";

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

// Generates the greeting the Agent speaks first, in-character — uses the
// same system prompt so it matches personality/relationship level. Falls
// back to a plain greeting if Grok fails, since a missing first message
// isn't worth failing the whole call start over.
async function generateFirstMessage(systemPrompt: string): Promise<string> {
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
            content: "[The call just connected. Say a short, natural opening greeting — 1 sentence, " +
              "in character, like you just picked up the phone. Nothing else, no explanation.]",
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
    const conversationId: string | undefined = body.conversationId;
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

    // Retrieval query text — last 3 prior chat messages for this
    // conversation (a call has no turns of its own yet at start time; the
    // conversation's `messages` table, shared with chat/index.ts, is the
    // only source of "what's currently being discussed"). No prior
    // messages (brand new conversation, or call started with no
    // conversationId) → empty string → fetchDirectiveMemoriesBehaviors
    // skips retrieval and injects no memories block, which is correct.
    let memoryQueryText = "";
    if (conversationId) {
      const { data: recentForQuery } = await db
        .from("messages")
        .select("content")
        .eq("conversation_id", conversationId)
        .order("created_at", { ascending: false })
        .limit(3);
      memoryQueryText = (recentForQuery ?? []).map((m) => m.content).reverse().join(" ").trim();
    }

    const { directive: fetchedDirective, memories, behaviors } =
      await fetchDirectiveMemoriesBehaviors(db, characterId, personalityRole, 1, conversationId ?? "", memoryQueryText);
    const directive = reviewMode ? REVIEW_DIRECTIVE : fetchedDirective;
    let systemPrompt = directive;
    systemPrompt += memoriesBlock(memories);
    systemPrompt += behaviorsBlock(behaviors);
    systemPrompt += VOICE_CALL_STYLE_RULE;
    systemPrompt += languageRule(language);

    const voiceId = character?.voice_id || elevenVoiceIdFor(personalityRole, vibe);
    const stability = stabilityFor(personalityRole);
    const firstMessage = await generateFirstMessage(systemPrompt);

    const { data: session, error } = await db.from("call_sessions").insert({
      user_id: uid,
      character_id: characterId,
      conversation_id: conversationId ?? null,
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
      firstMessage,
    });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
