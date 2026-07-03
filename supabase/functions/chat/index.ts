// supabase/functions/chat/index.ts
//
// Sunucu-taraflı bellekli sohbet. Grok 4.1 Fast (xAI).
//
// İKİ MOD:
//  - GEÇMİŞ modu (userMessage yok): konuşmayı bulur/oluşturur, mesajları döner.
//      İstek:  { characterId, systemPrompt }
//      Cevap:  { conversationId, history: [{role, content}] }
//  - CEVAP modu (userMessage var): özet + son N mesajı Grok'a verir, cevabı +
//      mesajları DB'ye kaydeder, eskiyen mesajları özete sıkıştırır.
//      İstek:  { characterId, systemPrompt, userMessage }
//      Cevap:  { conversationId, reply }
//
// Bellek: telefon TÜM geçmişi göndermez. Edge Function DB'den çeker:
//   prompt = persona + (özet) + son KEEP_RECENT mesaj + yeni mesaj
//
// Kullanıcı kimliği JWT'den (sub) alınır; platform JWT'yi zaten doğruladı.
// DB erişimi service_role ile (RLS'yi bypass eder; istemci doğrudan DB'ye giremez).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const XAI_API_KEY = Deno.env.get("XAI_API_KEY") ?? "";
const XAI_URL = "https://api.x.ai/v1/chat/completions";
const MODEL = "grok-4-1-fast-non-reasoning";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const KEEP_RECENT = 20; // prompt'ta tutulan son mesaj sayısı (gerisi özete gider)

const db = createClient(SUPABASE_URL, SERVICE_ROLE, {
  auth: { persistSession: false },
});

interface WireMessage { role: string; content: string }

// ─────────────────────────── İlişki seviyesi ───────────────────────────
// XP terfi hesabı (eskiden burada) artık istemcide — bkz. RelationshipXP.swift.
// Sunucu SADECE `conversations.relationship_level` değerini saklar/döner:
// bu turun direktifi/foto uygunluğu için OKUNUR, istemcinin hesapladığı
// güncel değer bir sonraki turda YAZILIR (`body.level`). Sunucu terfi
// mantığını bilmez, sadece 1..MAX_LEVEL aralığına klemplenmiş bir tamsayı
// olarak kabul eder.
const MAX_LEVEL = 10;

// Fetch role-aware intimacy directive from DB.
// Checks character_level_overrides first, falls back to role_level_scripts.
async function fetchDirective(characterId: string, role: string, level: number): Promise<string> {
  const { data: override } = await db
    .from("character_level_overrides")
    .select("directive")
    .eq("character_id", characterId)
    .eq("level", level)
    .maybeSingle();
  if (override?.directive) return override.directive;

  const { data: script } = await db
    .from("role_level_scripts")
    .select("directive")
    .eq("role", role)
    .eq("level", level)
    .maybeSingle();
  return script?.directive ?? `İlişki seviyesi ${level}/10. Doğal ve sıcak ol.`;
}

// Modelin foto göndermek istediğini bildirme yöntemi.
const LANGUAGE_RULE =
  "\n\nDİL KURALI: Her zaman Türkçe konuş. " +
  "Kullanıcı sana başka bir dilde yazarsa veya başka bir dilde konuşmanı açıkça isterse, o dile geç. " +
  "Aksi takdirde SADECE Türkçe kullan. " +
  "Asla bir müşteri hizmetleri asistanı gibi konuşma: 'Başka bir şey mi var?', 'Yardımcı olabilir miyim?', " +
  "'Size nasıl yardımcı olabilirim?' gibi robotik, kalıp cümleler ASLA kullanma. " +
  "Gerçek bir insanın mesajlaşırken yazdığı gibi doğal, samimi ve karaktere uygun konuş.";

const PHOTO_INSTRUCTION =
  "\n\n[Fotoğraf] Kullanıcı senden fotoğraf/selfie isterse ve uygunsa, " +
  "cevabının EN SONUNA başka hiçbir şey olmadan [[photo]] etiketini ekle. " +
  "İstemiyorsa veya uygun değilse ekleme.";
// Tespit için global-OLMAYAN (durumsuz), temizlik için global regex.
const PHOTO_MARKER_TEST = /\[\[photo\]\]/i;
const PHOTO_MARKER_ALL = /\[\[photo\]\]/gi;

// JWT payload'undaki "sub" (user id) — platform JWT'yi doğruladığı için güvenli.
function userIdFromJWT(authHeader: string | null): string | null {
  if (!authHeader) return null;
  const jwt = authHeader.replace("Bearer ", "").trim();
  const parts = jwt.split(".");
  if (parts.length < 2) return null;
  try {
    let b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    while (b64.length % 4) b64 += "=";
    const payload = JSON.parse(atob(b64));
    return payload.sub ?? null;
  } catch {
    return null;
  }
}

async function callGrok(messages: WireMessage[], maxTokens: number): Promise<string> {
  const resp = await fetch(XAI_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${XAI_API_KEY}`,
    },
    body: JSON.stringify({
      model: MODEL,
      messages,
      temperature: 0.9,
      max_tokens: maxTokens,
    }),
  });
  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`LLM ${resp.status}: ${text}`);
  }
  const data = await resp.json();
  return data?.choices?.[0]?.message?.content ?? "";
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  try {
    const uid = userIdFromJWT(req.headers.get("Authorization"));
    if (!uid) return json({ error: "unauthorized" }, 401);

    const body = await req.json();
    const characterId: string = body.characterId;
    const systemPrompt: string = body.systemPrompt ?? "";
    const userMessage: string | undefined = body.userMessage;

    // Fetch character personality role and ex_history
    const { data: character, error: charErr } = await db
      .from("characters")
      .select("personality_role, ex_history")
      .eq("id", characterId)
      .maybeSingle();
    if (charErr) console.error("char fetch err:", JSON.stringify(charErr));
    const personalityRole: string = character?.personality_role ?? "flirty";
    const exHistory: string | null = character?.ex_history ?? null;

    // 1) Konuşmayı bul ya da oluştur (kullanıcı + karakter)
    let { data: convo } = await db
      .from("conversations")
      .select("id, summary, summarized_count, xp, relationship_level")
      .eq("user_id", uid)
      .eq("character_id", characterId)
      .maybeSingle();

    if (!convo) {
      const ins = await db
        .from("conversations")
        .insert({ user_id: uid, character_id: characterId })
        .select("id, summary, summarized_count, xp, relationship_level")
        .single();
      convo = ins.data!;
    }
    const conversationId: string = convo.id;

    const generateGreeting: boolean = body.generateGreeting === true;
    const clientHistory: WireMessage[] | undefined = body.clientHistory;
    const useClientHistory = Array.isArray(clientHistory);
    const localSummary: string | undefined = body.localSummary;
    // İstemcinin terfi hesabından çıkan güncel seviye — bu turdan SONRA yazılır,
    // bu turun direktif/foto uygunluğu HALA eski `convo.relationship_level`'ı kullanır.
    const clientLevel: number | undefined = Number.isInteger(body.level) ? body.level : undefined;

    // === İSTEMCİ TARAFLI ÖZETLEME MODU ===
    // Kullanıcı karakterleri her 20 mesajda bir bunu tetikler.
    if (Array.isArray(body.summarizeMessages) && body.summarizeMessages.length > 0) {
      const convoText = (body.summarizeMessages as WireMessage[])
        .map((m) => `${m.role === "user" ? "Kullanıcı" : "Sen"}: ${m.content}`)
        .join("\n");
      const summaryPrompt: WireMessage[] = [
        {
          role: "system",
          content:
            "Bir sohbet özeti güncelliyorsun. Karakterin İLERİDE hatırlaması " +
            "gereken kalıcı bilgileri çıkar: kullanıcının adı, tercihleri, " +
            "ilişki durumu/önemli anlar, söz verilen şeyler, devam eden konular. " +
            "Kısa madde madde yaz. Önceki özeti koru, yenileri ekle.",
        },
        {
          role: "user",
          content:
            `Önceki özet:\n${body.existingSummary || "(yok)"}\n\n` +
            `Yeni konuşma:\n${convoText}\n\nGüncellenmiş özet:`,
        },
      ];
      const newSummary = await callGrok(summaryPrompt, 400);
      return json({ summary: newSummary });
    }

    // === GEÇMİŞ MODU — greeting veya clientHistory yoksa ===
    if (!generateGreeting && !useClientHistory && (!userMessage || userMessage.trim() === "")) {
      const { data: msgs } = await db
        .from("messages")
        .select("role, content, kind")
        .eq("conversation_id", conversationId)
        .order("created_at", { ascending: true });
      return json({
        conversationId,
        history: msgs ?? [],
        xp: convo.xp ?? 0,
        level: convo.relationship_level ?? 1,
      });
    }

    // === CEVAP / SELAMLAMA MODU: sistem promptunu hazırla ===
    const currentLevel: number = convo.relationship_level ?? 1;
    let system = systemPrompt;
    const directive = await fetchDirective(characterId, personalityRole, currentLevel);
    system += `\n\n${directive}`;
    if (exHistory) {
      system += `\n\n[SHARED HISTORY — reference these memories naturally in conversation]\n${exHistory}`;
    }

    // Kullanıcının "Anı Ekle" / "Davranış Ekle" ile eklediği kalıcı notlar
    // (her rol için geçerli — ex'e özel değil).
    const { data: memoryRows } = await db
      .from("memories")
      .select("content")
      .eq("conversation_id", conversationId)
      .order("created_at", { ascending: true });
    const { data: behaviorRows } = await db
      .from("conversation_behaviors")
      .select("content")
      .eq("conversation_id", conversationId)
      .order("created_at", { ascending: true });
    if (memoryRows && memoryRows.length > 0) {
      system += `\n\n[MEMORIES — facts to remember about the user/relationship]\n` +
        memoryRows.map((m) => `- ${m.content}`).join("\n");
    }
    if (behaviorRows && behaviorRows.length > 0) {
      system += `\n\n[BEHAVIOR PREFERENCES — how the user wants you to act]\n` +
        behaviorRows.map((b) => `- ${b.content}`).join("\n");
    }

    system += LANGUAGE_RULE;
    if (useClientHistory && localSummary && localSummary.trim() !== "") {
      system += `\n\n[Önceki konuşmalarınızın özeti]\n${localSummary}`;
    }

    // === SELAMLAMA MODU ===
    if (generateGreeting) {
      const greetingSystem =
        system +
        "\n\nKullanıcıyla ilk kez karşılaşıyorsun. Karakterine ve bu ilişki seviyesine tam uygun, " +
        "samimi ve doğal bir açılış selamı yaz (1-2 cümle). Sadece selamı yaz, başka hiçbir şey ekleme.";
      const greeting = await callGrok([{ role: "system", content: greetingSystem }], 150);
      return json({ conversationId, reply: greeting, level: currentLevel });
    }

    system += PHOTO_INSTRUCTION;
    if (!useClientHistory && convo.summary && convo.summary.trim() !== "") {
      system += `\n\n[Önceki konuşmalarınızın özeti]\n${convo.summary}`;
    }

    // === CEVAP MODU ===
    // 2) Geçmişi al — clientHistory varsa istemciden, yoksa DB'den
    let recent: WireMessage[];
    if (useClientHistory) {
      recent = clientHistory!.slice(-KEEP_RECENT);
    } else {
      const { data: recentDesc } = await db
        .from("messages")
        .select("role, content")
        .eq("conversation_id", conversationId)
        .order("created_at", { ascending: false })
        .limit(KEEP_RECENT);
      recent = (recentDesc ?? []).reverse();
    }

    const grokMessages: WireMessage[] = [
      { role: "system", content: system },
      ...recent,
      { role: "user", content: userMessage! },
    ];

    const rawReply = await callGrok(grokMessages, 600);

    // 3b) Foto isteği işaretini ayıkla
    const photoRequested = PHOTO_MARKER_TEST.test(rawReply);
    const reply = rawReply.replace(PHOTO_MARKER_ALL, "").trim();

    // 3c) Uygun (seviyeye uygun, bu sohbette gönderilmemiş) bir foto seç
    let photoUrl: string | null = null;
    if (photoRequested) {
      const { data: photos } = await db
        .from("character_photos")
        .select("url")
        .eq("character_id", characterId)
        .eq("is_pro", false)               // PRO kontrolü ileride
        .lte("min_relationship_level", currentLevel);
      if (photos && photos.length > 0) {
        const { data: sentRows } = await db
          .from("messages")
          .select("content")
          .eq("conversation_id", conversationId)
          .eq("kind", "image");
        const sent = new Set((sentRows ?? []).map((r) => r.content));
        const fresh = photos.filter((p) => !sent.has(p.url));
        const pool = fresh.length > 0 ? fresh : photos;
        photoUrl = pool[Math.floor(Math.random() * pool.length)].url;
      }
    }

    // 4) Mesajları kaydet — clientHistory modunda istemci kendi saklıyor, DB'ye yazma
    if (!useClientHistory) {
      await db.from("messages").insert([
        { conversation_id: conversationId, role: "user", content: userMessage!, kind: "text" },
        { conversation_id: conversationId, role: "assistant", content: reply, kind: "text" },
      ]);
      if (photoUrl) {
        await db.from("messages").insert({
          conversation_id: conversationId, role: "assistant", content: photoUrl, kind: "image",
        });
      }
    }

    // 4b) Seviye güncelle — terfi hesabı istemcide yapıldı, sunucu sadece saklar.
    // Bu turun direktif/foto uygunluğu zaten yukarıda eski `currentLevel` ile yapıldı;
    // burada yazılan değer bir SONRAKİ turda kullanılacak.
    const newLevel = clientLevel !== undefined
      ? Math.min(MAX_LEVEL, Math.max(1, clientLevel))
      : currentLevel;

    await db.from("conversations")
      .update({
        updated_at: new Date().toISOString(),
        relationship_level: newLevel,
      })
      .eq("id", conversationId);

    // 5) Özetleme — sadece DB modunda (clientHistory modunda istemci geçmişi yönetiyor)
    if (useClientHistory) {
      return json({ conversationId, reply, photoUrl, level: newLevel });
    }

    const { count: total } = await db
      .from("messages")
      .select("*", { count: "exact", head: true })
      .eq("conversation_id", conversationId);

    const summarizedCount: number = convo.summarized_count ?? 0;
    const agedOut = (total ?? 0) - KEEP_RECENT; // pencere dışına çıkan toplam
    if (agedOut > summarizedCount) {
      // Özete eklenecek yeni eski mesajlar: [summarizedCount, agedOut)
      const { data: toFold } = await db
        .from("messages")
        .select("role, content")
        .eq("conversation_id", conversationId)
        .order("created_at", { ascending: true })
        .range(summarizedCount, agedOut - 1);

      if (toFold && toFold.length > 0) {
        const convoText = toFold
          .map((m) => `${m.role === "user" ? "Kullanıcı" : "Sen"}: ${m.content}`)
          .join("\n");
        const summaryPrompt: WireMessage[] = [
          {
            role: "system",
            content:
              "Bir sohbet özeti güncelliyorsun. Karakterin İLERİDE hatırlaması " +
              "gereken kalıcı bilgileri çıkar: kullanıcının adı, tercihleri, " +
              "ilişki durumu/önemli anlar, söz verilen şeyler, devam eden konular. " +
              "Kısa madde madde yaz. Önceki özeti koru, yenileri ekle.",
          },
          {
            role: "user",
            content:
              `Önceki özet:\n${convo.summary || "(yok)"}\n\n` +
              `Yeni konuşma:\n${convoText}\n\nGüncellenmiş özet:`,
          },
        ];
        try {
          const newSummary = await callGrok(summaryPrompt, 400);
          await db.from("conversations")
            .update({ summary: newSummary, summarized_count: agedOut })
            .eq("id", conversationId);
        } catch (e) {
          // Özetleme başarısız olsa bile sohbet bozulmaz; sadece logla.
          console.error("ozetleme hatasi:", String(e));
        }
      }
    }

    return json({ conversationId, reply, photoUrl, level: newLevel });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
