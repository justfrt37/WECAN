// supabase/functions/set-nickname/index.ts
//
// Pro+/Max only (bkz. _shared/entitlements.ts requireNicknameEntitlement).
// İki yön: "character" (kullanıcının karakteri yeniden adlandırması — salt
// kozmetik, hiçbir prompta girmez) ve "user" (karakterin kullanıcıya nasıl
// hitap edeceği — chat/index.ts sistem promptuna girer, bu yüzden
// add-character-note'un "Davranış Ekle" ile AYNI regex-only enjeksiyon
// kontrolünden geçer, Grok sınıflandırıcısı GEREKMEZ).
//
//   İstek:  { characterId, kind: "character" | "user", content }
//           content boş string → alanı temizler (nickname kaldırma).
//   Cevap:  { ok: true }

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireNicknameEntitlement } from "../_shared/entitlements.ts";

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

// add-character-note/index.ts'deki INJECTION_PATTERNS ile BİREBİR aynı liste
// (kasıtlı — "user" nickname da "Davranış Ekle" gibi doğrudan prompta giriyor).
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

const MAX_LENGTH = 30;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);

    const gate = await requireNicknameEntitlement(db, uid);
    if (gate) return json(gate.body, gate.status);

    const b = await req.json();
    const characterId: string = b.characterId;
    const kind: string = b.kind;
    const content: string = (b.content ?? "").toString().trim().slice(0, MAX_LENGTH);

    if (!characterId) return json({ error: "characterId required" }, 400);
    if (kind !== "character" && kind !== "user") {
      return json({ error: "kind must be 'character' or 'user'" }, 400);
    }

    if (kind === "user" && content && looksLikeInjection(content)) {
      return json({ error: "Invalid content." }, 400);
    }

    // Konuşmayı bul ya da oluştur — add-character-note ile aynı upsert deseni
    // (conversations(user_id, character_id) UNIQUE).
    let { data: convo } = await db
      .from("conversations")
      .select("id")
      .eq("user_id", uid)
      .eq("character_id", characterId)
      .maybeSingle();

    if (!convo) {
      const ins = await db
        .from("conversations")
        .upsert({ user_id: uid, character_id: characterId }, { onConflict: "user_id,character_id" })
        .select("id")
        .single();
      convo = ins.data!;
    }

    const column = kind === "character" ? "character_nickname" : "user_nickname";
    const { error: updErr } = await db
      .from("conversations")
      .update({ [column]: content || null })
      .eq("id", convo.id);
    if (updErr) return json({ error: updErr.message }, 500);

    return json({ ok: true });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
