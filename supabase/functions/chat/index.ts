// supabase/functions/chat/index.ts
//
// Sunucu-taraflı bellekli sohbet. Grok 4.1 Fast (xAI).
//
// ÜÇ MOD:
//  - TEMİZLE modu (clearConversation: true): konuşma satırını siler (messages/
//      memories cascade ile birlikte gider). İstemci "Clear Chat" için kullanır.
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
  "Aksi takdirde SADECE Türkçe kullan. Hangi dilde konuşuyorsan konuş, asla bir müşteri " +
  "hizmetleri asistanı ya da resmi bir kurum gibi çıkma — gerçek bir insanın sevgilisine/" +
  "arkadaşına o dilde mesajlaşırken kullanacağı doğal, samimi ifadeleri seç.";

const PHOTO_INSTRUCTION =
  "\n\n[Fotoğraf] Kullanıcı senden fotoğraf/selfie isterse ve uygunsa, " +
  "cevabının EN SONUNA başka hiçbir şey olmadan [[photo]] etiketini ekle. " +
  "İstemiyorsa veya uygun değilse ekleme.";
// Tespit için global-OLMAYAN (durumsuz), temizlik için global regex.
const PHOTO_MARKER_TEST = /\[\[photo\]\]/i;
const PHOTO_MARKER_ALL = /\[\[photo\]\]/gi;

// Belirli kalıp cümleleri yasaklamak (blocklist) işe yaramıyor — model yine de
// onları üretebiliyor (negatif talimatlar LLM'lerde güvenilir değil). Bunun yerine
// modele NİYET/DUYGU seviyesinde düşünmesini ve o niyeti her seferinde doğal,
// o dile özgü, FARKLI bir ifadeyle anlatmasını söylüyoruz. Rol bağımsız, her
// bota (baked-in system_prompt'u ne olursa olsun) her turda uygulanır.
const VARIATION_RULE =
  "\n\nDOĞALLIK VE ÇEŞİTLİLİK KURALI: Bir şey söylemeden önce, iletmek istediğin " +
  "NİYETİ ya da DUYGUYU netleştir (ör. mesafe koymak, ilgisizlik göstermek, bir " +
  "konuyu kapatmak, şüphe/kıskançlık, özlem, sıcaklık, merak, soru sormak isteği, " +
  "onay/reddetme). Sonra o niyeti/duyguyu HER SEFERİNDE farklı kelimelerle, farklı " +
  "cümle yapısıyla, farklı uzunlukta anlat — konuştuğun dilde gerçek bir insanın " +
  "o niyeti ifade etmek için kullanacağı çeşit çeşit doğal yollardan birini seç " +
  "(bazen soru sorarak, bazen dolaylı bir göndermeyle, bazen kendi hislerini " +
  "itiraf ederek, bazen şakayla, bazen kısa ve öz, bazen daha açık). Aynı niyeti " +
  "anlatmak için ASLA ezberlenmiş/kalıplaşmış tek bir cümleye güvenme ve onu tekrar " +
  "tekrar kullanma — özellikle resmî, robotik ya da kurumsal bir asistan gibi " +
  "duyulan hiçbir ifadeye asla başvurma. Konuşmayı hep aynı noktaya kilitleme; " +
  "her mesaj sohbeti bir adım ileri taşısın.";

// Model bazen kendi bir önceki mesajına (soru, sitem, bekleyiş) verilen cevabı
// görmezden gelip sanki hiç cevap gelmemiş gibi devam ediyor — özellikle o "önceki
// mesaj" bir bildirime dokunulunca istemci tarafından eklenen hazır bir açılış
// cümlesiyse (jealousy/ghosted/liked bait — bkz. JealousyContent.swift vb.), çünkü
// bunlar Grok'un kendi ürettiği bir şey değil. Modele bunları da KENDİ sözleri
// gibi ele almasını ve kullanıcının son mesajının onlara cevap olup olmadığını
// kontrol etmesini söylüyoruz.
const CONTINUITY_RULE =
  "\n\nSÜREKLİLİK KURALI: Cevap vermeden önce mesaj geçmişindeki EN SON kendi " +
  "(assistant rolündeki) mesajına bak — bu senin o an ürettiğin bir cevap olabileceği " +
  "gibi, kullanıcı bir bildirime dokunduğunda otomatik eklenen kısa bir açılış/sitem " +
  "cümlesi de olabilir; ikisi de SENİN sözlerindir, aynı ciddiyetle ele al. O mesajda " +
  "bir soru sordun mu, bir şey mi bekledin, bir sitemde mi bulundun? Sonra kullanıcının " +
  "SON mesajının buna cevap olup olmadığını kontrol et — kısa bir cevap, bir espri/" +
  "kelime oyunu, dolaylı bir yanıt bile olsa bunu fark et. Kullanıcı zaten cevap " +
  "verdiyse ASLA sanki hiç cevap vermemiş gibi aynı soruyu tekrar sorma veya konuyu " +
  "görmezden gelip başka bir şeye atlama — verdiği cevabı gerçekten duymuş gibi, " +
  "ona gönderme yaparak devam et.";

// İlişki seviyesine göre mizah/şaka/kelime oyunu dozu — samimiyet arttıkça artar.
function humorDirective(level: number): string {
  if (level <= 3) {
    return "\n\nMİZAH: Ara sıra hafif bir espri ya da tatlı bir sataşma yapabilirsin, " +
      "ama abartma — ilişki daha yeni, samimiyet arttıkça açılırsın.";
  }
  if (level <= 6) {
    return "\n\nMİZAH: Rahatsan laf sokuşturma, kelime oyunları ve şakalaşma yap; " +
      "ruh haline göre esprili ol.";
  }
  return "\n\nMİZAH: Aranızdaki samimiyete güvenerek bol bol şakalaş, kelime " +
    "oyunları ve sadece ikinizin anlayacağı esprili göndermeler yap; flörtöz takılabilirsin.";
}

// Son mesajdan bu yana geçen süre + günün saatine göre doğal davranış yönergesi.
function timeContext(lastMs?: number, nowMs?: number, tzMin?: number): string {
  if (typeof lastMs !== "number" || typeof nowMs !== "number") return "";
  const gapS = Math.max(0, (nowMs - lastMs) / 1000);
  let gap: string;
  if (gapS < 120) gap = "az önce (birkaç saniye/dakika)";
  else if (gapS < 3600) gap = `${Math.round(gapS / 60)} dakika`;
  else if (gapS < 86400) gap = `${Math.round(gapS / 3600)} saat`;
  else gap = `${Math.round(gapS / 86400)} gün`;
  const localHour = Math.floor((((nowMs / 1000) + (tzMin ?? 0) * 60) % 86400) / 3600);
  const partOfDay =
    localHour < 6 ? "gece geç saat" : localHour < 12 ? "sabah" :
    localHour < 18 ? "öğleden sonra" : "akşam";
  return `\n\n[ZAMAN] Kullanıcının son mesajından bu yana ~${gap} geçti. ` +
    `Şu an ${partOfDay} (yaklaşık saat ${localHour}). Buna uygun, doğal davran: ` +
    `uzun aradan sonra bunu doğal şekilde belli et (özledim / neredeydin gibi), ` +
    `günün saatine göre ton/selam seç. Bunu her mesajda tekrar etme, sadece uygunsa.`;
}

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

    // === SOHBETİ TEMİZLE === İstemcinin "Clear Chat" eylemi — konuşma satırını
    // siler (messages/memories cascade ile birlikte gider), bir sonraki açılışta
    // sıfırdan (yeni bir "ilk selam" akışıyla) başlar.
    if (body.clearConversation === true) {
      const { data: existing } = await db
        .from("conversations")
        .select("id")
        .eq("user_id", uid)
        .eq("character_id", characterId)
        .maybeSingle();
      if (existing) {
        await db.from("conversations").delete().eq("id", existing.id);
      }
      return json({ ok: true });
    }

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

    const clientHistory: WireMessage[] | undefined = body.clientHistory;
    const useClientHistory = Array.isArray(clientHistory);
    const localSummary: string | undefined = body.localSummary;
    // İstemcinin terfi hesabından çıkan güncel seviye — bu turdan SONRA yazılır,
    // bu turun direktif/foto uygunluğu HALA eski `convo.relationship_level`'ı kullanır.
    const clientLevel: number | undefined = Number.isInteger(body.level) ? body.level : undefined;
    // Zaman farkındalığı: son mesaj zamanı, istemcinin "şimdi"si ve saat dilimi
    // farkı (dakika) — hepsi epoch ms. Sadece varsa kullanılır (bkz. timeContext).
    const lastMessageAt: number | undefined = typeof body.lastMessageAt === "number" ? body.lastMessageAt : undefined;
    const clientNow: number | undefined = typeof body.clientNow === "number" ? body.clientNow : undefined;
    const tzOffsetMinutes: number | undefined = typeof body.tzOffsetMinutes === "number" ? body.tzOffsetMinutes : undefined;

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

    // === GEÇMİŞ MODU — clientHistory yoksa ===
    if (!useClientHistory && (!userMessage || userMessage.trim() === "")) {
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

    // === CEVAP MODU: sistem promptunu hazırla ===
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
    system += VARIATION_RULE;
    system += CONTINUITY_RULE;
    system += humorDirective(currentLevel);
    system += timeContext(lastMessageAt, clientNow, tzOffsetMinutes);
    if (useClientHistory && localSummary && localSummary.trim() !== "") {
      system += `\n\n[Önceki konuşmalarınızın özeti]\n${localSummary}`;
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
