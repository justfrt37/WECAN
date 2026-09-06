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

import { callLLMStream } from "../_shared/llm.ts";
import { createStreamTagSanitizer } from "../_shared/voiceTags.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

interface WireMessage { role: string; content: string }

/// Upstream SSE'yi ElevenLabs'e iletmeden ÖNCE süzen dönüştürücü.
///
/// NEDEN VAR: eskiden stream `tee()` ile ikiye ayrılıp bir kopyası ElevenLabs'e
/// HAM olarak iletiliyordu; yani modelin uydurduğu bir ses etiketini
/// yakalayacak hiçbir nokta yoktu ve "prompt disiplini tek savunma" diye
/// yazılıydı. O savunma canlıda düştü: cevabın ortasındaki `[slow]` — hiçbir
/// zaman var olmamış bir etiket — kullanıcıya "slow" diye okundu. Etiket
/// listesi artık burada da uygulanıyor (bkz. _shared/voiceTags.ts), yani
/// tanınmayan bir etiket sese dönüşemez.
///
/// Ayrıca `tee()` ihtiyacı da ortadan kalktı: temizlenmiş metin aynı geçişte
/// birikiyor ve tur sonunda call_turns'e yazılıyor — loga giden metin artık
/// kullanıcının GERÇEKTEN duyduğu metinle birebir aynı.
function sanitizeSseStream(
  upstream: ReadableStream<Uint8Array>,
  onComplete: (replyText: string) => void,
): ReadableStream<Uint8Array> {
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  const sanitizer = createStreamTagSanitizer();
  let buffer = "";
  let replyText = "";
  // Son görülen chunk'ın iskeleti: flush edilen artık metni aynı biçimde
  // yollayabilmek için lazım (id/model/finish_reason alanlarını korur).
  // deno-lint-ignore no-explicit-any
  let lastChunk: any = null;

  function emitLine(line: string, controller: TransformStreamDefaultController<Uint8Array>) {
    controller.enqueue(encoder.encode(line + "\n"));
  }

  function handleLine(rawLine: string, controller: TransformStreamDefaultController<Uint8Array>) {
    const trimmed = rawLine.trim();
    if (!trimmed.startsWith("data: ")) {
      // Yorum satırları (`: ping`) ve boş satırlar aynen geçer — SSE
      // çerçevelemesini bozmamak için.
      emitLine(rawLine, controller);
      return;
    }
    if (trimmed === "data: [DONE]") {
      const rest = sanitizer.flush();
      if (rest && lastChunk) {
        replyText += rest;
        const tail = { ...lastChunk, choices: [{ ...lastChunk.choices[0], delta: { content: rest }, finish_reason: null }] };
        emitLine("data: " + JSON.stringify(tail), controller);
      }
      emitLine(rawLine, controller);
      return;
    }
    // deno-lint-ignore no-explicit-any
    let parsed: any;
    try {
      parsed = JSON.parse(trimmed.slice(6));
    } catch {
      // Ayrıştırılamayan chunk'ı DEĞİŞTİRMEDEN geçir: sözleşmeyi bozmaktansa
      // o parçayı süzmemek yeğdir.
      emitLine(rawLine, controller);
      return;
    }
    const choice = parsed?.choices?.[0];
    const content = choice?.delta?.content;
    if (typeof content !== "string" || content.length === 0) {
      if (parsed?.choices) lastChunk = parsed;
      emitLine(rawLine, controller);
      return;
    }
    lastChunk = parsed;
    const clean = sanitizer.push(content);
    replyText += clean;
    // İçerik tamamen tutulduysa (etiket ortada bölünmüş) boş delta gider —
    // OpenAI biçiminde boş delta olağan, ElevenLabs bunu sorunsuz yutuyor.
    choice.delta.content = clean;
    emitLine("data: " + JSON.stringify(parsed), controller);
  }

  return upstream.pipeThrough(
    new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, controller) {
        buffer += decoder.decode(chunk, { stream: true });
        const lines = buffer.split("\n");
        buffer = lines.pop() ?? "";
        for (const line of lines) handleLine(line, controller);
      },
      flush(controller) {
        if (buffer) handleLine(buffer, controller);
        const rest = sanitizer.flush();
        if (rest && lastChunk) {
          replyText += rest;
          const tail = { ...lastChunk, choices: [{ ...lastChunk.choices[0], delta: { content: rest }, finish_reason: null }] };
          emitLine("data: " + JSON.stringify(tail), controller);
        }
        onComplete(replyText.trim());
      },
    }),
  );
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
    // being asked to speak again. The timeout itself is AGENT-SIDE config
    // (`conversation_config.turn.turn_timeout`), not settable from here —
    // it is set to 10s via scripts/elevenlabs-agent.sh; the wording below
    // has to match that number or the character sounds like she's
    // panicking after two seconds of quiet. Detectable here: the LAST message in the
    // running history isn't from the user (it's the agent's own prior
    // line). Without a signal, Grok would generate a reply as if
    // responding to something just said — flag it with a one-off
    // instruction appended ONLY for this Grok call (never stored/logged —
    // logging below still uses the real `messages` history, not this).
    const isSilenceReengage = messages.length > 0 && messages[messages.length - 1].role !== "user";
    const grokMessages: WireMessage[] = isSilenceReengage
      ? [...messages, {
          role: "user",
          content: "[The user has gone quiet for about ten seconds — you're re-engaging, not responding to " +
            "something they just said. Sound natural about noticing the silence, in character: check in, " +
            "tease them about going quiet, or just continue naturally, whatever actually fits your " +
            "personality right now. Keep it short.]",
        }]
      : messages;

    // callLLMStream ham upstream Response'u veriyor, govdesi tuketilmemis
    // halde -- asagidaki sanitize + iletim onu tek gecişte tuketiyor.
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

    // Stream ElevenLabs'e İLETİLMEDEN önce ses etiketlerinden süzülüyor
    // (bkz. sanitizeSseStream). Temizlenen metin aynı geçişte birikiyor;
    // stream bitince aşağıdaki callback tur kaydını yazıyor.
    // `!` kesin-atama işareti: Promise yürütücüsü senkron çalışıyor, yani
    // resolveReply bir sonraki satırda kesinlikle atanmış oluyor; TS bunu
    // kendi başına göremiyor.
    let resolveReply!: (text: string) => void;
    const replyPromise = new Promise<string>((res) => { resolveReply = res; });
    const forwardStream = sanitizeSseStream(upstream.body, (text) => resolveReply(text));

    const logPromise = (async () => {
      const replyText = await replyPromise;
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
