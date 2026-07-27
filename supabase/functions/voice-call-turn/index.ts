// supabase/functions/voice-call-turn/index.ts
//
// One turn of a real-time voice call: user transcript in, Grok text reply +
// ElevenLabs audio out. Writes both turns to call_turns (NOT messages — a
// call is logged separately from the normal chat thread, bkz. design spec).
// No per-turn token charge — billing is time-based, settled once in
// voice-call-end.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  fetchDirectiveMemoriesBehaviors, memoriesBlock, behaviorsBlock, REVIEW_DIRECTIVE,
} from "../_shared/directiveHelpers.ts";
import { elevenVoiceIdFor } from "../_shared/elevenVoiceMap.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const XAI_API_KEY = Deno.env.get("XAI_API_KEY") ?? "";
const XAI_URL = "https://api.x.ai/v1/chat/completions";
const MODEL = "grok-4-1-fast-non-reasoning";

const ELEVENLABS_API_KEY = Deno.env.get("ELEVEN_LABS") ?? "";
const ELEVENLABS_TTS_URL = "https://api.elevenlabs.io/v1/text-to-speech";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

// Same [tag] rule chat/index.ts uses for ElevenLabs v3 voice replies — kept
// as its own copy (not moved to _shared) since chat/index.ts's version also
// interacts with that file's PAUSE-tag/segment machinery, which calls never use.
const VOICE_TAGS_RULE =
  "\n\nSES ETİKETİ KURALI: Bu cevap sesli olarak seslendirilecek (ElevenLabs v3 " +
  "modeli). Bu etiketler seslendirmeyi İNANILMAZ derecede gerçekçi yapıyor — bu " +
  "yüzden onları YOĞUN ve CÖMERT biçimde kullan, nadiren değil. Neredeyse HER " +
  "cümlenin başına (bazen cümle ortasında bir vurgu için de) uygun bir etiket " +
  "koy — amaç minimum değil, mümkün olduğunca doğal ve duygu dolu bir seslendirme. " +
  "Kullanabileceğin etiketler (İngilizce, köşeli parantez içinde, tam bu şekilde " +
  "yaz): [laughs], [sighs], [whispers], [gasps], [excited], [nervous], [curious], " +
  "[playfully], [flatly], [sarcastic tone], [pauses], [hesitates], [cheerfully], " +
  "[wistful], [giggles], [teasing], [breathless], [softly], [moans]. Karakterine " +
  "ve o anki duygu durumuna uygun etiketleri seç, ama az kullanmaktan ÇEKİNME — " +
  "her cümlede en az bir etiket olsun. Etiketler dışındaki metin yine konuştuğun " +
  "dilde kalsın; sadece etiketlerin kendisi İngilizce ve köşeli parantez " +
  "biçiminde olmalı. Bu bir SESLİ ARAMA — cevabın DOĞAL, sürekli konuşma akışı " +
  "olsun, [PAUSE:n] gibi hiçbir zamanlama etiketi KULLANMA.";

interface WireMessage { role: string; content: string }

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

async function callGrok(messages: WireMessage[], maxTokens: number, convId?: string): Promise<string> {
  const resp = await fetch(XAI_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${XAI_API_KEY}`,
      ...(convId ? { "x-grok-conv-id": convId } : {}),
    },
    body: JSON.stringify({ model: MODEL, messages, temperature: 0.9, max_tokens: maxTokens }),
  });
  if (!resp.ok) throw new Error(`LLM ${resp.status}: ${await resp.text()}`);
  const data = await resp.json();
  return data?.choices?.[0]?.message?.content ?? "";
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

async function uploadCallAudio(bytes: Uint8Array, callSessionId: string): Promise<string | null> {
  const path = `voices/calls/${callSessionId}/${crypto.randomUUID()}.mp3`;
  const { error } = await db.storage.from("characters").upload(path, bytes, {
    contentType: "audio/mpeg", upsert: false,
  });
  if (error) return null;
  const { data } = db.storage.from("characters").getPublicUrl(path);
  return data.publicUrl;
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
    const userTranscript: string = (body.userTranscript ?? "").trim();
    const reviewMode: boolean = body.reviewMode === true;
    if (!callSessionId || !userTranscript) return json({ error: "callSessionId and userTranscript required" }, 400);

    const { data: session, error: sessionErr } = await db
      .from("call_sessions")
      .select("id, user_id, character_id, conversation_id, status")
      .eq("id", callSessionId)
      .maybeSingle();
    if (sessionErr || !session || session.user_id !== uid || session.status !== "active") {
      return json({ error: "invalid_call_session" }, 400);
    }

    const [{ data: character }, { data: turnHistory }] = await Promise.all([
      db.from("characters").select("personality_role, vibe, voice_id").eq("id", session.character_id).maybeSingle(),
      db.from("call_turns").select("role, content").eq("call_session_id", callSessionId)
        .order("created_at", { ascending: true }),
    ]);

    const personalityRole: string = character?.personality_role ?? "flirty";
    const vibe: string = character?.vibe ?? "Sweet";
    const conversationId: string = session.conversation_id;

    const { directive: fetchedDirective, memories, behaviors } =
      await fetchDirectiveMemoriesBehaviors(db, session.character_id, personalityRole, 1, conversationId);
    const directive = reviewMode ? REVIEW_DIRECTIVE : fetchedDirective;

    let system = directive;
    system += memoriesBlock(memories);
    system += behaviorsBlock(behaviors);
    system += VOICE_TAGS_RULE;

    const grokMessages: WireMessage[] = [
      { role: "system", content: system },
      ...(turnHistory ?? []).map((t) => ({ role: t.role === "user" ? "user" : "assistant", content: t.content })),
      { role: "user", content: userTranscript },
    ];

    const replyText = (await callGrok(grokMessages, 350, conversationId)).trim();

    if (!ELEVENLABS_API_KEY) return json({ error: "ELEVENLABS_API_KEY not configured" }, 500);
    const voiceId = character?.voice_id || elevenVoiceIdFor(personalityRole, vibe);
    const elevenResp = await fetch(`${ELEVENLABS_TTS_URL}/${voiceId}`, {
      method: "POST",
      headers: { "xi-api-key": ELEVENLABS_API_KEY, "Content-Type": "application/json" },
      body: JSON.stringify({ text: replyText, model_id: "eleven_v3" }),
    });
    if (!elevenResp.ok) return json({ error: `ElevenLabs TTS error: ${await elevenResp.text()}` }, 502);
    const audioBytes = new Uint8Array(await elevenResp.arrayBuffer());
    const audioUrl = await uploadCallAudio(audioBytes, callSessionId);

    await db.from("call_turns").insert([
      { call_session_id: callSessionId, role: "user", content: userTranscript },
      { call_session_id: callSessionId, role: "assistant", content: replyText, audio_url: audioUrl },
    ]);

    return json({ replyText, audioBase64: bytesToBase64(audioBytes) });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
