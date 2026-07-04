// supabase/functions/voice-message-tts/index.ts
//
// Sesli mesaj (voice-note) sentezi — 28 karakter sesi (role×vibe) + 7 dil,
// Google Cloud Text-to-Speech (Chirp3-HD). Var olan `tts` fonksiyonundan
// (OpenAI, tek sabit ses, eski konuşma-balonu-seslendirme özelliği) BİLEREK
// AYRI TUTULDU — o fonksiyon ve onu çağıran istemci kodu hiç değişmedi.
// DB erişimi yok — tamamen bağımsız fonksiyon.

import { voiceNameFor } from "./voiceMap.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const GOOGLE_TTS_API_KEY = Deno.env.get("GOOGLE_TTS_API_KEY") ?? "";
const GOOGLE_TTS_URL = "https://texttospeech.googleapis.com/v1/text:synthesize";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const text: string | undefined = body.text;
    const role: string | undefined = body.role;
    const vibe: string | undefined = body.vibe;
    const lang: string | undefined = body.lang;

    if (!text || !text.trim() || !role || !vibe || !lang) {
      return new Response(
        JSON.stringify({ error: "text, role, vibe, lang are all required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }
    if (!GOOGLE_TTS_API_KEY) {
      return new Response(
        JSON.stringify({ error: "GOOGLE_TTS_API_KEY not configured" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const voiceName = voiceNameFor(role, vibe, lang);
    const localeCode = voiceName.split("-Chirp3-HD-")[0];

    const googleResp = await fetch(`${GOOGLE_TTS_URL}?key=${GOOGLE_TTS_API_KEY}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        input: { text },
        voice: { languageCode: localeCode, name: voiceName },
        audioConfig: { audioEncoding: "MP3" },
      }),
    });

    if (!googleResp.ok) {
      const errBody = await googleResp.text();
      return new Response(
        JSON.stringify({ error: `Google TTS error: ${errBody}` }),
        { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const { audioContent } = await googleResp.json(); // base64 mp3
    const bytes = Uint8Array.from(atob(audioContent), (c) => c.charCodeAt(0));

    return new Response(bytes, {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "audio/mpeg" },
    });
  } catch (error) {
    return new Response(
      JSON.stringify({ error: String(error) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
