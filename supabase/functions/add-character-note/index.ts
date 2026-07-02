// supabase/functions/add-character-note/index.ts
//
// Sohbet ayarları menüsünden "Anı Ekle" / "Davranış Ekle" — kullanıcının
// kendi (user, character) konuşmasına kalıcı bir not ekler. Grok ile aynı
// prompt-injection kontrolünden geçer (validate-history, ex_history ile
// aynı kontrol).
//
//   İstek:  { characterId, kind: "memory" | "behavior", content }
//   Cevap:  { ok: true }

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const db = createClient(SUPABASE_URL, SERVICE_ROLE, {
  auth: { persistSession: false },
});

// "Davranış Ekle" içeriği doğası gereği talimat şeklindedir ("bana hep X de"),
// bu yüzden validate-history'nin "talimat mı, geçmiş mi" Grok sınıflandırıcısından
// GEÇİRİLMEZ — neredeyse her davranış isteğini INJECTION olarak işaretler.
// Sadece bariz jailbreak kalıplarını yakalayan hafif bir yerel kontrol yeterli.
const INJECTION_PATTERNS = [
  /ignore (previous|prior|all) instructions?/i,
  /you are now/i,
  /disregard/i,
  /system:/i,
  /\[system\]/i,
  /forget (everything|all|your)/i,
  /new (persona|role|character|instructions?)/i,
  /act as (an? )?(AI|assistant|jailbreak|DAN)/i,
  /override/i,
  /prompt injection/i,
];

function looksLikeInjection(text: string): boolean {
  return INJECTION_PATTERNS.some((p) => p.test(text));
}

function userIdFromJWT(authHeader: string | null): string | null {
  if (!authHeader) return null;
  const jwt = authHeader.replace("Bearer ", "").trim();
  const parts = jwt.split(".");
  if (parts.length < 2) return null;
  try {
    let b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    while (b64.length % 4) b64 += "=";
    return JSON.parse(atob(b64)).sub ?? null;
  } catch {
    return null;
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);

    const b = await req.json();
    const characterId: string = b.characterId;
    const kind: string = b.kind;
    const content: string = (b.content ?? "").toString().trim();

    if (!characterId) return json({ error: "characterId required" }, 400);
    if (kind !== "memory" && kind !== "behavior") {
      return json({ error: "kind must be 'memory' or 'behavior'" }, 400);
    }
    if (!content) return json({ error: "content required" }, 400);

    if (kind === "memory") {
      // Geçmiş/anı metni — validate-history'nin Grok sınıflandırıcısı uygun
      // (ex_history ile aynı doğrulama).
      const valResp = await fetch(`${SUPABASE_URL}/functions/v1/validate-history`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${SERVICE_ROLE}` },
        body: JSON.stringify({ history: content }),
      });
      const valResult = await valResp.json();
      if (!valResult.valid) {
        return json({ error: valResult.reason ?? "Invalid content." }, 400);
      }
    } else {
      // Davranış talimatı — sadece bariz jailbreak kalıplarını reddet.
      if (looksLikeInjection(content)) {
        return json({ error: "Invalid content." }, 400);
      }
    }

    // Konuşmayı bul ya da oluştur (kullanıcı + karakter) — chat fonksiyonuyla aynı desen.
    let { data: convo } = await db
      .from("conversations")
      .select("id")
      .eq("user_id", uid)
      .eq("character_id", characterId)
      .maybeSingle();

    if (!convo) {
      const ins = await db
        .from("conversations")
        .insert({ user_id: uid, character_id: characterId })
        .select("id")
        .single();
      convo = ins.data!;
    }
    const conversationId: string = convo.id;

    const table = kind === "memory" ? "memories" : "conversation_behaviors";
    const { error: insErr } = await db.from(table).insert({ conversation_id: conversationId, content });
    if (insErr) return json({ error: insErr.message }, 500);

    return json({ ok: true });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
