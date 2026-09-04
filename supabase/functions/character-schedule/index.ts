// supabase/functions/character-schedule/index.ts
//
// Karakterin system_prompt'undan (kişilik/meslek/vibe zaten içinde) günlük
// bir rutin (hafta içi + hafta sonu) üretir — ilk sohbet açıldığında,
// henüz hiç mesaj yokken çağrılır (bkz. ChatViewModel.ensureScheduleGenerated).
// Sonraki güncellemeler chat/index.ts'nin özetleme moduna binmiş şekilde olur.
//
//   İstek:  { characterId, systemPrompt }  (Authorization: Bearer <JWT> zorunlu)
//   Cevap:  { schedule: { weekday: [...], weekend: [...] } }  veya  { error }

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { callLLM } from "../_shared/llm.ts";
const XAI_URL = "https://api.x.ai/v1/chat/completions";
const MODEL = "grok-4.3";

// Üretilen rutini KALICI yazmak için (service-role → RLS baypas).
const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

function userIdFromJWT(authHeader: string | null): string | null {
  if (!authHeader) return null;
  const jwt = authHeader.replace("Bearer ", "").trim();
  const parts = jwt.split(".");
  if (parts.length < 2) return null;
  try {
    let b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    while (b64.length % 4) b64 += "=";
    return JSON.parse(atob(b64)).sub ?? null;
  } catch { return null; }
}

// Left to its own devices, the model piles most characters onto the same
// average times (e.g. dinner 18:00-19:00) — multiple bots show "having
// dinner" at once. Each generation RANDOMLY picks a "chronotype" and makes
// it a MANDATORY anchor in the prompt, so real structural variety emerges
// across characters (relying on LLM temperature alone wasn't enough).
// This is a "chat until late" app — NO character should go to bed before
// 01:00 (user request, 2026-07). Some chronotypes used to give early sleep
// times like 21:30/23:00, so bots would say "I'm going to bed" even during
// an active chat. All sleep times were pushed past 01:00; wake times stayed
// the same for realism (see the extra hardcoded baseline in
// buildScheduleInstructions too).
const CHRONOTYPES = [
  "Early riser but late sleeper: wakes 05:30-06:30, eats dinner early " +
  "(17:30-18:30), sleeps 01:00-01:30.",
  "Standard 9-to-5 type: wakes 07:00-07:30, eats dinner 19:00-20:00, " +
  "sleeps 01:30-02:00.",
  "Night owl: wakes 09:30-10:30, eats dinner late (20:30-21:30), sleeps " +
  "02:30-03:30.",
  "Freelance/irregular worker: meal times shift day to day and don't " +
  "follow a fixed pattern; may skip traditional meal times and snack " +
  "instead. Sleep time is NEVER before 01:00, usually varies 02:00-04:00.",
  "Shift worker / unusual hours: works evenings or nights, eats their " +
  "main meal at an unusual time like 15:00 or 22:00. Sleep time is NEVER " +
  "before 01:00, can be 03:00-05:00 depending on when work ends.",
];

function buildScheduleInstructions(interests: string[]): string {
  const chronotype = CHRONOTYPES[Math.floor(Math.random() * CHRONOTYPES.length)];
  const interestsNote = interests.length > 0
    ? `Character's interests: ${interests.join(", ")}. Color in fitting ` +
      "free-time/weekend blocks with these (e.g. if there's an outdoor " +
      "hobby, make one weekend block that; if there's a gaming/home hobby, " +
      "make one evening free-time block that) — but NOT every block, only " +
      "where it makes sense; don't force an interest into a block it " +
      "conflicts with (work/sleep). "
    : "";
  return (
    "Generate a realistic daily routine (weekday + weekend) for this " +
    "character. Write concrete time blocks fitting their personality and " +
    "profession — cover the ENTIRE day with no gaps, sleep included. " +
    "Weekend should be DIFFERENT from weekday (most professions aren't " +
    "7 days a week). " + interestsNote +
    `DETERMINE WAKE/MEAL/SLEEP TIMES USING THIS PATTERN: ${chronotype} ` +
    "Apply it unless it CLEARLY conflicts with the character's actual " +
    "profession (e.g. someone working night shift can't be an early " +
    "riser); if it conflicts, keep the pattern's SPIRIT (e.g. " +
    "irregular/unusual hours) adapted to the profession instead. " +
    "HARD RULE: the sleep block (isSleep:true) can NEVER start before " +
    "01:00 — this is an app people chat in until late, no character goes " +
    "to bed before 01:00, no matter what the pattern above says. Never " +
    "break this rule. " +
    "The `label` field should be a SHORT status phrase — read like a " +
    "natural answer to \"what are they doing right now\" (e.g. \"At work\" " +
    "not \"Work\", \"Having dinner\" not \"Dinner\", \"Commuting home\" not " +
    "\"Commute\", \"Asleep\" not \"Sleep\"). " +
    "Always write in the character's own reply language (see the language " +
    "rule in the system prompt) — if the character speaks Turkish, " +
    "label/detail should be Turkish too, never auto-switch to English. " +
    "Set `isSleep` to `true` on the block(s) where the character is " +
    "ASLEEP, `false` on all others — usually one sleep block per day. " +
    "Respond with ONLY this JSON schema, nothing else (no markdown code " +
    "block either):\n" +
    '{"weekday":[{"start":"HH:mm","end":"HH:mm","label":"short status ' +
    'phrase","detail":"more detailed description","isSleep":false}],' +
    '"weekend":[...]}'
  );
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
    const systemPrompt: string = (b.systemPrompt ?? "").toString().trim();
    const interests: string[] = Array.isArray(b.interests) ? b.interests : [];
    if (!characterId) return json({ error: "characterId required" }, 400);
    if (!systemPrompt) return json({ error: "systemPrompt required" }, 400);

    const raw: string = await callLLM(
      [
        { role: "system", content: `${systemPrompt}\n\n${buildScheduleInstructions(interests)}` },
        { role: "user", content: "Generate the schedule JSON now." },
      ],
      // 0.8 -> 0.4: bu cagri JSON uretiyor, sicaklik sadece ayristirilamaz
      // cikti riskini artiriyor. Program cesitliligi zaten
      // buildScheduleInstructions icindeki varyasyondan geliyor.
      { maxTokens: 1500, temperature: 0.4 },
    );
    const match = raw.match(/\{[\s\S]*\}/);
    if (!match) return json({ error: "no_json_in_response" }, 502);

    let parsed: any;
    try {
      parsed = JSON.parse(match[0]);
    } catch (e) {
      return json({ error: `invalid_json: ${String(e)}` }, 502);
    }
    if (!Array.isArray(parsed.weekday) || !Array.isArray(parsed.weekend)) {
      return json({ error: "invalid_schedule_shape" }, 502);
    }

    const schedule = { weekday: parsed.weekday, weekend: parsed.weekend };

    // Üretilen rutini, VARSA kullanıcının bu karakterle konuşmasına KALICI yaz
    // (conversations.schedule, migration 009). Böylece her açılışta yeniden
    // ÜRETİLMEZ — hydrateConversations bunu geri okur, ensureGenerated atlar
    // (bkz. "her açılışta rutin üretimi → aşırı LLM isteği" sorunu). Konuşma
    // YOKSA OLUŞTURMA (hayalet sohbet olmasın); mesajlaşınca oluşan konuşmaya
    // bir sonraki üretimde yazılır. Best-effort: yazma başarısız olsa da rutini döndür.
    try {
      const { data: convo } = await db.from("conversations").select("id")
        .eq("user_id", uid).eq("character_id", characterId)
        .order("updated_at", { ascending: false }).limit(1);
      if (convo && convo[0]) {
        await db.from("conversations").update({ schedule }).eq("id", convo[0].id);
      }
    } catch (persistErr) {
      console.error("schedule persist err:", String(persistErr));
    }

    return json({ schedule });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
