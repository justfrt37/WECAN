// supabase/functions/_shared/elevenVoiceMap.ts
//
// Karakter -> ElevenLabs voice_id seçimi.
//
// TARİHÇE / NEDEN BÖYLE: Bu dosya önce `role_vibe` -> voice_id şeklinde 28
// sabit girdilik bir tablo idi ve 7 rol × 4 vibe varsayıyordu (crazy/distant/
// ex/shy × Elegant/Energetic/Mysterious/Sweet). Rol ve vibe taksonomisi
// sonradan değişti, tablo güncellenmedi ve şu hale geldi: haritanın 7 rolünden
// 4'ü (crazy, distant, ex, shy) artık hiç üretilmiyor, veritabanının 7 rolünden
// 4'ü (bratty, confident, mysterious, sweet) haritada hiç yoktu, vibe sayısı
// 4'ten 20'ye çıktı. Sonuç: `voice_id`si boş olan 15 karakterin TAMAMI
// haritada eşleşme bulamayıp aynı DEFAULT sese (Luna) düşüyordu — 15 farklı
// karakter tek bir sesle konuşuyordu.
//
// Yeni tasarım bunu yapısal olarak imkânsız kılıyor:
//   1) Anahtar artık ROL. Rol kümesi kapalı ve DB ile aynı (7 değer).
//   2) Vibe serbest metin (20+ değer, kullanıcı/LLM üretiyor) — o yüzden ASLA
//      anahtar değil, sadece opsiyonel ince ayar (VIBE_PIN).
//   3) Eşleşme bulunamaması diye bir durum yok: her rolün havuzu dolu, bilinmeyen
//      rol de FALLBACK_POOL'a düşüyor. Tek bir sese çökme mümkün değil.
//   4) Seçim deterministik (seed hash'i) — aynı karakter her zaman aynı sesi alır.
//
// SES SEÇİMİ İLKESİ: yalnızca hikâye anlatımı / romantik / sıcak tonlar.
// Kurumsal, eğitmen, "çağrı merkezi" tonundaki sesler bilinçli olarak dışarıda
// bırakıldı (bkz. EXCLUDED). Yeni ses eklerken aynı çizgiyi koru —
// docs/VOICE_SELECTION.md.

/// Havuzlarda kullanılan seslerin okunabilir adları. Sadece log/dokümantasyon
/// amaçlı; çalışma zamanında kimse buna bakmıyor.
export const VOICE_NAMES: Record<string, string> = {
  "6j8uSqQkZH2WrWDVIiRB": "Luna — Late Night Sweetheart",
  "QDBL6ATWz3YtwddGAE6E": "Emma — Fresh, Calm and Soft",
  "Nggzl2QAXh3OijoXD116": "Candy — Young and Sweet",
  "4uXpMV2FG1JKkCQKIdSH": "Meshell — Warm Loving Calm",
  "tSFrmifcoKA2lXImR5MW": "Iris — Warm, Intimate & Narrative",
  "8quEMRkSpwEaWBzHvTLv": "Veda Sky — Cozy Late Night Storyteller",
  "m0MqfGOWTAfVVEaz4KxX": "Alexandra",
  "eVItLK1UvXctxuaRV2Oq": "Jean — Alluring and Playful Femme Fatale",
  "YgzytRZyVmEux6PCtJYB": "Ivanna — Sultry, Fun and Captivating",
  "YZHSTqsq1isdXNsFLzBw": "Olivia — Smooth, Charming, Persuasive",
  "Qbw4VpyUrHEG7NigKzty": "Kristen — Cold Evil Queen Villain",
  "sssn4wp3AspuK2kvy3Ym": "Vivien — Mysterious Witch",
  "e6qsVnCuD0MWxmhZcuKz": "Mia — Elegant Storyteller",
  "rdEILoSxdT6xKDZ56abJ": "Isla Wilde",
  "WLjZnm4PkNmYtNCyiCq8": "Lisa — Youthful, Fun and Witty",
  "FGY2WhTYpPnrIDTdsKH5": "Laura — Enthusiast, Quirky Attitude",
  "cgSgspJ2msm6clMCkdW9": "Jessica — Playful, Bright, Warm",
  "n7Wi4g1bhpw4Bs8HK5ph": "Gigi — Cute, Peppy, Energetic",
  "xctasy8XvGp2cVO9HL9k": "Allison — Energetic, Clear and Bubbly",
  "eaNNqnkhfRYVtX7U7VLj": "Clara — Emotional, Dramatic and Polished",
  "pFZP5JQG7iQjIQuC4Bku": "Lily — Velvety Actress",
  "ITRml9f5K7moz24wRnmV": "Cass — Warm & Energetic British Woman",
};

/// Eski haritada olup KASTEN havuzlara alınmayan sesler. Hepsi kurumsal /
/// bilgilendirici / eğitmen tonunda — bir AI arkadaş karakteri için yanlış.
/// Buraya bir ses eklemek onu havuzlardan kalıcı olarak eler.
export const EXCLUDED: Record<string, string> = {
  "PFqo8D2UY6vd5tzJUrsl": "Miss B. — Inspirational, Authoritative, Confident",
  "Xb7hH8MSUJpSbSDYk0k2": "Alice — Clear, Engaging Educator",
  "EXAVITQu4vr4xnSDxMaL": "Sarah — Mature, Reassuring, Confident",
  "SAz9YHcvj6GT2YYXdXww": "River — Relaxed, Neutral, Informative",
  "wQ7dVQFxIqwokkwsMqqn": "Neslihan — Psychology & Mind-Focused",
  "LtYRTlMfWU5Q6Me90AIR": "Lily D — Clear, Calm, Expressive",
};

/// characters.personality_role -> ses havuzu. Rol kümesi KAPALI ve DB'dekiyle
/// birebir. Yeni bir rol eklenirse buraya da havuz eklenmeli, yoksa o rol
/// FALLBACK_POOL kullanır (çalışır ama tona özel olmaz).
export const ROLE_POOL: Record<string, string[]> = {
  sweet: [
    "6j8uSqQkZH2WrWDVIiRB", // Luna
    "QDBL6ATWz3YtwddGAE6E", // Emma
    "Nggzl2QAXh3OijoXD116", // Candy
  ],
  devoted: [
    "4uXpMV2FG1JKkCQKIdSH", // Meshell
    "tSFrmifcoKA2lXImR5MW", // Iris
    "8quEMRkSpwEaWBzHvTLv", // Veda Sky
    "m0MqfGOWTAfVVEaz4KxX", // Alexandra
  ],
  flirty: [
    "eVItLK1UvXctxuaRV2Oq", // Jean
    "YgzytRZyVmEux6PCtJYB", // Ivanna
    "YZHSTqsq1isdXNsFLzBw", // Olivia
  ],
  mysterious: [
    "Qbw4VpyUrHEG7NigKzty", // Kristen
    "sssn4wp3AspuK2kvy3Ym", // Vivien
    "e6qsVnCuD0MWxmhZcuKz", // Mia
  ],
  bratty: [
    "rdEILoSxdT6xKDZ56abJ", // Isla Wilde
    "WLjZnm4PkNmYtNCyiCq8", // Lisa
    "FGY2WhTYpPnrIDTdsKH5", // Laura
  ],
  playful: [
    "cgSgspJ2msm6clMCkdW9", // Jessica
    "n7Wi4g1bhpw4Bs8HK5ph", // Gigi
    "xctasy8XvGp2cVO9HL9k", // Allison
  ],
  confident: [
    "eaNNqnkhfRYVtX7U7VLj", // Clara
    "pFZP5JQG7iQjIQuC4Bku", // Lily
    "ITRml9f5K7moz24wRnmV", // Cass
  ],
};

/// Bilinmeyen rol için. Rol havuzlarından tonca en "nötr romantik" olanlar.
const FALLBACK_POOL = [
  "6j8uSqQkZH2WrWDVIiRB", // Luna
  "tSFrmifcoKA2lXImR5MW", // Iris
  "e6qsVnCuD0MWxmhZcuKz", // Mia
  "YZHSTqsq1isdXNsFLzBw", // Olivia
];

/// Opsiyonel ince ayar: `${role}_${vibe}` -> voice_id. SADECE vibe'ın sesi
/// açıkça belirlediği durumlar için. Buradaki değer HER ZAMAN o rolün
/// havuzunda olmalı (aksi halde havuz mantığı delinir — testi aşağıda).
/// Vibe serbest metin olduğu için burası hiçbir zaman "tam" olmayacak; eşleşme
/// yoksa havuzdan deterministik seçim devreye girer, bu bir hata değil.
export const VIBE_PIN: Record<string, string> = {
  sweet_Sweet: "6j8uSqQkZH2WrWDVIiRB", // Luna
  sweet_Warm: "QDBL6ATWz3YtwddGAE6E", // Emma
  sweet_Cheerful: "Nggzl2QAXh3OijoXD116", // Candy
  devoted_Gentle: "4uXpMV2FG1JKkCQKIdSH", // Meshell
  devoted_Attentive: "tSFrmifcoKA2lXImR5MW", // Iris
  devoted_Devoted: "8quEMRkSpwEaWBzHvTLv", // Veda Sky
  flirty_Sultry: "YgzytRZyVmEux6PCtJYB", // Ivanna
  flirty_Mysterious: "eVItLK1UvXctxuaRV2Oq", // Jean
  mysterious_Enigmatic: "Qbw4VpyUrHEG7NigKzty", // Kristen
  mysterious_Ethereal: "e6qsVnCuD0MWxmhZcuKz", // Mia
  mysterious_Mysterious: "sssn4wp3AspuK2kvy3Ym", // Vivien
  bratty_Bratty: "WLjZnm4PkNmYtNCyiCq8", // Lisa
  bratty_Mischievous: "rdEILoSxdT6xKDZ56abJ", // Isla Wilde
  playful_Playful: "cgSgspJ2msm6clMCkdW9", // Jessica
  playful_Bubbly: "xctasy8XvGp2cVO9HL9k", // Allison
  confident_Commanding: "eaNNqnkhfRYVtX7U7VLj", // Clara
  confident_Bold: "pFZP5JQG7iQjIQuC4Bku", // Lily
};

export function poolFor(role: string): string[] {
  const pool = ROLE_POOL[role];
  return pool && pool.length ? pool : FALLBACK_POOL;
}

/// FNV-1a — küçük, bağımsız, platformlar arası aynı sonucu veren hash.
/// Math.random KULLANILMIYOR: aynı karakterin her çağrıda aynı sesi alması
/// şart, yoksa aynı karakter aramada bir sesle, sesli mesajda başka bir sesle
/// konuşur.
function hash(s: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = (h * 0x01000193) >>> 0;
  }
  return h >>> 0;
}

/// ÇALIŞMA ZAMANI fallback'i — `characters.voice_id` boş olan (eski) satırlar
/// için. Yeni karakterlerde voice_id oluşturma anında yazıldığı için buraya
/// hiç düşülmemesi beklenir (bkz. pickVoiceIdForNewCharacter).
///
/// `seed` verilirse (karakter id'si) seçim karaktere göre dağılır: aynı
/// role+vibe'a sahip iki karakter farklı ses alır. Verilmezse `role_vibe`
/// hash'lenir — deterministik ama aynı kombinasyon aynı sesi paylaşır.
export function elevenVoiceIdFor(role: string, vibe?: string, seed?: string): string {
  const pool = poolFor(role);
  if (vibe) {
    const pinned = VIBE_PIN[`${role}_${vibe}`];
    // Pin yalnızca seed YOKKEN uygulanır: seed varsa havuza dağıtmak
    // (aynı role+vibe'lı karakterlerin farklı ses alması) daha değerli.
    if (pinned && !seed && pool.includes(pinned)) return pinned;
  }
  const key = seed && seed.length ? seed : `${role}_${vibe ?? ""}`;
  return pool[hash(key) % pool.length];
}

/// YENİ KARAKTER için ses seçer ve `characters.voice_id`ye yazılmak üzere döner.
/// `usedInRole`: aynı role sahip mevcut karakterlerin voice_id'leri. Havuzdaki
/// EN AZ kullanılan ses seçilir, böylece 3-4 sesli havuz gerçekten dağılır ve
/// "hepsi aynı sesle konuşuyor" durumu tekrar oluşamaz. Eşitlikte vibe pin'i,
/// o da yoksa deterministik hash karar verir — yani aynı girdi aynı sonucu verir.
export function pickVoiceIdForNewCharacter(
  role: string,
  vibe: string | undefined,
  usedInRole: string[],
  seed?: string,
): string {
  const pool = poolFor(role);
  const counts = new Map<string, number>(pool.map((v) => [v, 0]));
  for (const v of usedInRole) {
    if (counts.has(v)) counts.set(v, (counts.get(v) ?? 0) + 1);
  }
  const min = Math.min(...pool.map((v) => counts.get(v) ?? 0));
  const leastUsed = pool.filter((v) => (counts.get(v) ?? 0) === min);
  if (leastUsed.length === 1) return leastUsed[0];
  const pinned = vibe ? VIBE_PIN[`${role}_${vibe}`] : undefined;
  if (pinned && leastUsed.includes(pinned)) return pinned;
  const key = seed && seed.length ? seed : `${role}_${vibe ?? ""}`;
  return leastUsed[hash(key) % leastUsed.length];
}

/// Konfigürasyon tutarlılığı — bir pin kendi rolünün havuzunda değilse ya da
/// havuza EXCLUDED bir ses sızmışsa isim listesi döner. Boş dizi = sağlıklı.
/// Deploy öncesi elle çağırmak için: `deno eval` / test.
export function auditVoiceConfig(): string[] {
  const problems: string[] = [];
  for (const [key, vid] of Object.entries(VIBE_PIN)) {
    const role = key.slice(0, key.indexOf("_"));
    if (!poolFor(role).includes(vid)) {
      problems.push(`VIBE_PIN["${key}"] -> ${vid} rolün havuzunda değil (${role})`);
    }
  }
  for (const [role, pool] of Object.entries(ROLE_POOL)) {
    if (!pool.length) problems.push(`ROLE_POOL["${role}"] boş`);
    for (const vid of pool) {
      if (vid in EXCLUDED) problems.push(`ROLE_POOL["${role}"] EXCLUDED ses içeriyor: ${vid}`);
      if (!(vid in VOICE_NAMES)) problems.push(`ROLE_POOL["${role}"] VOICE_NAMES'te olmayan ses: ${vid}`);
    }
    if (new Set(pool).size !== pool.length) problems.push(`ROLE_POOL["${role}"] tekrar eden ses içeriyor`);
  }
  return problems;
}
