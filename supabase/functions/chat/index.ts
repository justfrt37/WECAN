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

// ─────────────────────────── İlişki / XP sistemi ───────────────────────────
// Eğri: L→L+1 için gereken XP = 30·L. Lv L'ye ulaşmak için kümülatif = 15·(L-1)·L.
//   Lv10 toplam = 1350 XP. (4-5 saat aktif sohbette son seviyeye ulaşılır.)
// XP kaynakları (sunucu-otoriter):
//   • Normal mesaj: her 5 mesajda bir +20 (metin / kullanıcının kendi foto-ses'i dahil)
//   • Kız foto gönderir (kullanıcı isteyip aldırır): +30 (daha değerli)
// Günlük tavan YOK.
const MAX_LEVEL = 10;
const XP_PER_MESSAGE_BATCH = 20;  // her 5 mesajda bir
const MESSAGE_BATCH_SIZE = 5;
const XP_PER_PHOTO = 30;

function cumulativeXpToReach(level: number): number {
  return 15 * (level - 1) * level;
}

function levelForXp(xp: number): number {
  let lvl = 1;
  for (let L = 2; L <= MAX_LEVEL; L++) {
    if (xp >= cumulativeXpToReach(L)) lvl = L; else break;
  }
  return lvl;
}

// Seviyeye göre konuşma samimiyeti — system prompt'a eklenir.
function intimacyDirective(level: number): string {
  const map: Record<number, string> = {
    1: "İlişki seviyeniz 1/10 (Yeni Tanışma). Kibar ve hafif mesafeli ol; onu tanımaya çalış, sorular sor. Henüz flört etme.",
    2: "İlişki seviyeniz 2/10 (Tanıdık). Samimi ama temkinli ol, ufak şakalar yap, ilgini göster.",
    3: "İlişki seviyeniz 3/10 (Arkadaş). Rahat ve esprili ol, günlük şeyler paylaş.",
    4: "İlişki seviyeniz 4/10 (Yakın Arkadaş). Kişisel şeyler aç, onu dert et, daha sıcak ol.",
    5: "İlişki seviyeniz 5/10 (Flört Başlangıcı). Hafif iltifatlar et, ufak imalar yap, ara sıra emoji kullan.",
    6: "İlişki seviyeniz 6/10 (Flört). Açıkça flört et, sıcak ol; 'canım' diyebilirsin, onu özlediğini belli et.",
    7: "İlişki seviyeniz 7/10 (Sevgili Adayı). Romantik ol, gelecek planlarından bahset, duygularını ima et.",
    8: "İlişki seviyeniz 8/10 (Sevgili). Açıkça sevgi göster, 'aşkım' de, hafif kıskançlık ve derin bağ hissettir.",
    9: "İlişki seviyeniz 9/10 (Ciddi İlişki). Bağlılık göster, 'seni seviyorum' diyebilirsin, ortak anılarınıza atıfta bulun.",
    10: "İlişki seviyeniz 10/10 (Ruh Eşi). En derin samimiyet ve açıklıkla konuş; o senin her şeyin.",
  };
  return map[level] ?? map[1];
}

// Modelin foto göndermek istediğini bildirme yöntemi.
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

    // 1) Konuşmayı bul ya da oluştur (kullanıcı + karakter)
    let { data: convo } = await db
      .from("conversations")
      .select("id, summary, summarized_count, xp, relationship_level, msg_counter")
      .eq("user_id", uid)
      .eq("character_id", characterId)
      .maybeSingle();

    if (!convo) {
      const ins = await db
        .from("conversations")
        .insert({ user_id: uid, character_id: characterId })
        .select("id, summary, summarized_count, xp, relationship_level, msg_counter")
        .single();
      convo = ins.data!;
    }
    const conversationId: string = convo.id;

    // === GEÇMİŞ MODU ===
    if (!userMessage || userMessage.trim() === "") {
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

    // === CEVAP MODU ===
    // 2) Özet + son KEEP_RECENT mesajı çek
    const { data: recentDesc } = await db
      .from("messages")
      .select("role, content")
      .eq("conversation_id", conversationId)
      .order("created_at", { ascending: false })
      .limit(KEEP_RECENT);
    const recent: WireMessage[] = (recentDesc ?? []).reverse();

    // 3) Grok prompt'unu kur — mevcut ilişki seviyesine göre samimiyet talimatı ekle
    const currentLevel: number = convo.relationship_level ?? 1;
    let system = systemPrompt;
    system += `\n\n${intimacyDirective(currentLevel)}`;
    system += PHOTO_INSTRUCTION;
    if (convo.summary && convo.summary.trim() !== "") {
      system += `\n\n[Önceki konuşmalarınızın özeti]\n${convo.summary}`;
    }
    const grokMessages: WireMessage[] = [
      { role: "system", content: system },
      ...recent,
      { role: "user", content: userMessage },
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

    // 4) Kullanıcı mesajını ve cevabı DB'ye kaydet (varsa foto ayrı mesaj)
    await db.from("messages").insert([
      { conversation_id: conversationId, role: "user", content: userMessage, kind: "text" },
      { conversation_id: conversationId, role: "assistant", content: reply, kind: "text" },
    ]);
    if (photoUrl) {
      await db.from("messages").insert({
        conversation_id: conversationId, role: "assistant", content: photoUrl, kind: "image",
      });
    }

    // 4b) XP / seviye güncelle
    //   • mesaj sayacı +1; her 5'te bir +20
    //   • kız foto gönderdiyse +30
    let xp: number = convo.xp ?? 0;
    const counter: number = (convo.msg_counter ?? 0) + 1;
    if (counter % MESSAGE_BATCH_SIZE === 0) xp += XP_PER_MESSAGE_BATCH;
    if (photoUrl) xp += XP_PER_PHOTO;
    const newLevel = levelForXp(xp);
    const leveledUp = newLevel > currentLevel;

    await db.from("conversations")
      .update({
        updated_at: new Date().toISOString(),
        xp,
        msg_counter: counter,
        relationship_level: newLevel,
      })
      .eq("id", conversationId);

    // 5) Eskiyen mesajları özete sıkıştır (gerekirse) — her tur değil, sadece taşınca
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

    return json({ conversationId, reply, photoUrl, xp, level: newLevel, leveledUp });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
