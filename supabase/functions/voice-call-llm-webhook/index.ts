// supabase/functions/voice-call-llm-webhook/index.ts
//
// ElevenLabs Agents' custom-LLM webhook target for real-time voice calls.
// Called by ElevenLabs' own infra (not the client) once per conversational
// turn, with the running OpenAI-format message history. The system prompt
// is already correct in that history because voice-call-start set it via
// AgentOverrides.prompt at call start — this function does NO directive/
// memory DB lookup of its own, just streams Grok's reply back as
// OpenAI-compatible SSE and logs the turn for later memory extraction.
//
// Authorization note: ElevenLabs' infra calls this directly, with no
// Supabase user JWT — the callSessionId (arriving via elevenlabs_extra_body,
// set by the client at conversation start) must resolve to a real `active`
// call_sessions row, which is this endpoint's only access control.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const XAI_API_KEY = Deno.env.get("XAI_API_KEY") ?? "";
import { callLLM, callLLMStream } from "../_shared/llm.ts";
const MODEL = "grok-4.3";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

interface WireMessage { role: string; content: string }

/// Reads an OpenAI-format SSE stream chunk-by-chunk, extracting each
/// delta's text content, and returns the accumulated full reply once the
/// stream ends. Used only for the background call_turns log — never blocks
/// the response already being forwarded to ElevenLabs.
async function accumulateReply(stream: ReadableStream<Uint8Array>): Promise<string> {
  let replyText = "";
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop() ?? "";
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed.startsWith("data: ") || trimmed === "data: [DONE]") continue;
      try {
        const delta = JSON.parse(trimmed.slice(6))?.choices?.[0]?.delta?.content;
        if (delta) replyText += delta;
      } catch {
        // Partial/non-JSON chunk split across two reads — skip, the next
        // read() call completes the line and buffer carries the remainder.
      }
    }
  }
  return replyText.trim();
}

Deno.serve(async (req: Request) => {
  try {
    const body = await req.json();
    const messages: WireMessage[] = body.messages ?? [];
    // The client sends this as `custom_llm_extra_body` in the conversation
    // initiation payload; we only ever read `elevenlabs_extra_body`, so if
    // ElevenLabs forwards it under the name the client used — or flattens it —
    // the id went missing and every turn was rejected with 400. That is what
    // the caller sees as "custom_llm_error: Failed to generate response from
    // custom LLM", and the edge log showed three consecutive
    // `POST | 400 | .../voice-call-llm-webhook/chat/completions`.
    // (Note the /chat/completions suffix: ElevenLabs treats the configured URL
    // as an OpenAI-compatible BASE url and appends the path itself.)
    // Accept every shape rather than guess which one is current.
    const extra = body.elevenlabs_extra_body ?? body.custom_llm_extra_body ?? {};
    const callSessionId: string | undefined = extra.callSessionId ?? body.callSessionId;

    if (!callSessionId) {
      // Log the envelope's shape, never its contents — this is the only way to
      // see what ElevenLabs actually sends without guessing again.
      console.error(
        "voice webhook: no callSessionId. top-level keys:",
        Object.keys(body ?? {}).join(","),
        "| extra keys:",
        Object.keys(extra ?? {}).join(","),
      );
      return new Response(JSON.stringify({ error: "missing callSessionId" }), { status: 400 });
    }
    const { data: session } = await db.from("call_sessions")
      .select("id, status").eq("id", callSessionId).maybeSingle();
    if (!session || session.status !== "active") {
      return new Response(JSON.stringify({ error: "invalid_call_session" }), { status: 400 });
    }

    const lastUserMessage = [...messages].reverse().find((m) => m.role === "user")?.content ?? "";

    // ElevenLabs also invokes this webhook on `turn_timeout` silence
    // re-engagement — no new user utterance arrived, the agent is just
    // being asked to speak again. Detectable here: the LAST message in the
    // running history isn't from the user (it's the agent's own prior
    // line). Without a signal, Grok would generate a reply as if
    // responding to something just said — flag it with a one-off
    // instruction appended ONLY for this Grok call (never stored/logged —
    // logging below still uses the real `messages` history, not this).
    const isSilenceReengage = messages.length > 0 && messages[messages.length - 1].role !== "user";
    const grokMessages: WireMessage[] = isSilenceReengage
      ? [...messages, {
          role: "user",
          content: "[The user has gone quiet for a few seconds — you're re-engaging, not responding to " +
            "something they just said. Sound natural about noticing the silence, in character: check in, " +
            "tease them about going quiet, or just continue naturally, whatever actually fits your " +
            "personality right now. Keep it short.]",
        }]
      : messages;

    // callLLMStream ham upstream Response'u veriyor, govdesi tuketilmemis
    // halde -- asagidaki tee() ve ElevenLabs'e iletim aynen calisiyor.
    // DeepSeek de xAI de OpenAI bicimli SSE uretiyor, iletilen sozlesme ayni.
    let upstream: Response;
    try {
      upstream = await callLLMStream(grokMessages, { maxTokens: 120, temperature: 0.9 });
    } catch (e) {
      return new Response(JSON.stringify({ error: String(e) }), { status: 502 });
    }
    if (!upstream.body) {
      return new Response(JSON.stringify({ error: "empty stream body" }), { status: 502 });
    }

    // Tee the upstream SSE stream: one copy forwarded to ElevenLabs untouched
    // (xAI's stream is already OpenAI-format — the exact contract ElevenLabs
    // expects), the other accumulated in the background to log the completed
    // turn once streaming finishes, without delaying the forwarded response.
    const [forwardStream, captureStream] = upstream.body.tee();

    const logPromise = (async () => {
      const replyText = await accumulateReply(captureStream);
      if (replyText) {
        // Sıralama artık call_turns.seq'e (identity kolonu, migration 024)
        // dayanıyor, created_at'e DEĞİL — bu fonksiyon HER turda ayrı bir
        // HTTP çağrısı olarak tetikleniyor (ElevenLabs), fire-and-forget
        // waitUntil ile, çağrılar arası hiçbir sıra garantisi yok; wall-clock
        // zaman damgası bu yüzden güvenilmezdi, Postgres'in insert-sırası
        // identity'si güvenilir.
        // Re-engage turns have no new user utterance — logging lastUserMessage
        // again would duplicate the same line as a fake "new" user turn.
        if (!isSilenceReengage) {
          await db.from("call_turns").insert({ call_session_id: callSessionId, role: "user", content: lastUserMessage });
        }
        await db.from("call_turns").insert({ call_session_id: callSessionId, role: "assistant", content: replyText });
      }
    })();
    // deno-lint-ignore no-explicit-any
    (globalThis as any).EdgeRuntime?.waitUntil(logPromise);

    return new Response(forwardStream, {
      headers: { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", Connection: "keep-alive" },
    });
  } catch (e) {
    console.error(String(e));
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});
