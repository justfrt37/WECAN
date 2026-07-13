// supabase/functions/voice-message-tts/index.ts
//
// Sesli mesaj (voice-note) sentezi — 28 karakter sesi (role×vibe) + 7 dil,
// Google Cloud Text-to-Speech (Chirp3-HD). Var olan `tts` fonksiyonundan
// (OpenAI, tek sabit ses, eski konuşma-balonu-seslendirme özelliği) BİLEREK
// AYRI TUTULDU — o fonksiyon ve onu çağıran istemci kodu hiç değişmedi.
// DB erişimi yok — tamamen bağımsız fonksiyon.
//
// `useElevenLabs: true` gelirse Google TTS yerine ElevenLabs eleven_v3 kullanılır
// — SADECE bu model [tag] ses etiketlerini (bkz. chat/index.ts VOICE_TAGS_RULE)
// anlıyor. Google TTS yolu bu durumda hiç çalışmaz, mevcut davranışı etkilemez.

import { voiceNameFor } from "./voiceMap.ts";
import { elevenVoiceIdFor } from "./elevenVoiceMap.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const GOOGLE_TTS_API_KEY = Deno.env.get("GOOGLE_TTS") ?? "";
const GOOGLE_TTS_URL = "https://texttospeech.googleapis.com/v1/text:synthesize";

const ELEVENLABS_API_KEY = Deno.env.get("ELEVEN_LABS") ?? "";
const ELEVENLABS_TTS_URL = "https://api.elevenlabs.io/v1/text-to-speech";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

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

async function chargeOrReject(uid: string, amount: number, reason: string): Promise<{ ok: true; balance: number } | { ok: false }> {
  const { data: charged } = await db.rpc("charge_tokens", { p_user_id: uid, p_amount: amount, p_reason: reason });
  if (!charged) return { ok: false };
  const { data: row } = await db.from("token_balances").select("balance").eq("user_id", uid).single();
  return { ok: true, balance: row?.balance ?? 0 };
}

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
    const useElevenLabs: boolean = body.useElevenLabs === true;
    // Per-character override (characters.voice_id, set by DEV-curated
    // character creation — see dev-create-character). Null/absent keeps the
    // existing role+vibe auto-map below (elevenVoiceIdFor).
    const voiceIdOverride: string | undefined = typeof body.voiceId === "string" && body.voiceId.trim() ? body.voiceId.trim() : undefined;

    if (!text || !text.trim() || !role || !vibe || !lang) {
      return new Response(
        JSON.stringify({ error: "text, role, vibe, lang are all required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) {
      return new Response(JSON.stringify({ error: "unauthorized" }), {
        status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    // Ucuz ön-kontrol — gerçek TTS çağrısını boşuna yapmamak için. Asıl
    // atomik düşüm sentez BAŞARIYLA tamamlandıktan sonra (aşağıdaki iki
    // başarı dönüşünden hemen önce).
    const { data: preCheckBalance } = await db.from("token_balances").select("balance").eq("user_id", uid).maybeSingle();
    if ((preCheckBalance?.balance ?? 0) < 12) {
      return new Response(JSON.stringify({ error: "insufficient_tokens" }), {
        status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (useElevenLabs) {
      if (!ELEVENLABS_API_KEY) {
        return new Response(
          JSON.stringify({ error: "ELEVENLABS_API_KEY not configured" }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }
      const voiceId = voiceIdOverride ?? elevenVoiceIdFor(role, vibe);
      const elevenResp = await fetch(`${ELEVENLABS_TTS_URL}/${voiceId}`, {
        method: "POST",
        headers: {
          "xi-api-key": ELEVENLABS_API_KEY,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ text, model_id: "eleven_v3" }),
      });
      if (!elevenResp.ok) {
        const errBody = await elevenResp.text();
        return new Response(
          JSON.stringify({ error: `ElevenLabs TTS error: ${errBody}` }),
          { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }
      const bytes = new Uint8Array(await elevenResp.arrayBuffer());
      const charge = await chargeOrReject(uid, 12, "voice");
      return new Response(bytes, {
        status: 200,
        headers: {
          ...corsHeaders, "Content-Type": "audio/mpeg",
          "X-Token-Balance": charge.ok ? String(charge.balance) : "",
        },
      });
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

    const charge = await chargeOrReject(uid, 12, "voice");
    return new Response(bytes, {
      status: 200,
      headers: {
        ...corsHeaders, "Content-Type": "audio/mpeg",
        "X-Token-Balance": charge.ok ? String(charge.balance) : "",
      },
    });
  } catch (error) {
    return new Response(
      JSON.stringify({ error: String(error) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
