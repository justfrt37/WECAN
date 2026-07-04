// supabase/functions/tts/voiceMap.ts
//
// 28 sesli-mesaj kombinasyonu (7 personality_role × 4 vibe) → Google Chirp3-HD
// ses ismi. Chirp3-HD isimleri TÜM dillerde aynı isimle var olduğu için
// (örn. "Aoede" hem tr-TR hem en-US hem de-DE'de mevcut), tek bir 28'lik
// harita 7 dilin hepsini kapsıyor — dil başına ayrı liste gerekmiyor.
//
// Adlandırma, deploy öncesi `voices:list` doğrulamasıyla teyit edilmeli
// (bkz. plan Task 3/4) — geçersiz çıkan isimler burada güncellenmeli.

const VOICE_MAP: Record<string, string> = {
  // flirty
  "flirty_Sweet": "Aoede",
  "flirty_Mysterious": "Kore",
  "flirty_Energetic": "Puck",
  "flirty_Elegant": "Zephyr",
  // distant
  "distant_Sweet": "Leda",
  "distant_Mysterious": "Charon",
  "distant_Energetic": "Orus",
  "distant_Elegant": "Umbriel",
  // shy
  "shy_Sweet": "Despina",
  "shy_Mysterious": "Enceladus",
  "shy_Energetic": "Erinome",
  "shy_Elegant": "Gacrux",
  // playful
  "playful_Sweet": "Autonoe",
  "playful_Mysterious": "Callirrhoe",
  "playful_Energetic": "Achird",
  "playful_Elegant": "Algenib",
  // devoted
  "devoted_Sweet": "Algieba",
  "devoted_Mysterious": "Alnilam",
  "devoted_Energetic": "Laomedeia",
  "devoted_Elegant": "Pulcherrima",
  // crazy
  "crazy_Sweet": "Rasalgethi",
  "crazy_Mysterious": "Sadachbia",
  "crazy_Energetic": "Sadaltager",
  "crazy_Elegant": "Fenrir",
  // ex
  "ex_Sweet": "Schedar",
  "ex_Mysterious": "Sulafat",
  "ex_Energetic": "Iapetus",
  "ex_Elegant": "Vindemiatrix",
};

const DEFAULT_VOICE = "Aoede";

// Lang'e (2 harfli: tr/en/de/fr/es/pt/it) Google locale'e çevirir.
const LOCALE_FOR_LANG: Record<string, string> = {
  tr: "tr-TR", en: "en-US", de: "de-DE", fr: "fr-FR",
  es: "es-ES", pt: "pt-PT", it: "it-IT",
};

export function voiceNameFor(role: string, vibe: string, lang: string): string {
  const chirpName = VOICE_MAP[`${role}_${vibe}`] ?? DEFAULT_VOICE;
  const locale = LOCALE_FOR_LANG[lang] ?? "en-US";
  return `${locale}-Chirp3-HD-${chirpName}`;
}
