// supabase/functions/_shared/voiceTags.ts
//
// Sesli aramada izin verilen ElevenLabs v3 ses etiketleri ve bunların
// TEK ortak temizleyicisi.
//
// NEDEN ORTAK: liste iki yerde birden lazım — voice-call-start açılış
// repliğini temizlerken, voice-call-llm-webhook ise tur cevaplarını
// ElevenLabs'e iletirken. Liste iki dosyada ayrı ayrı dursaydı biri
// güncellenip diğeri unutulduğunda fark ancak sesli olarak, kullanıcının
// kulağında ortaya çıkardı.
//
// LİSTENİN KAYNAĞI: https://elevenlabs.io/docs/best-practices/prompting/eleven-v3
// Kılavuzda GEÇMEYEN hiçbir etiket buraya eklenmemeli. Tanınmayan etiket
// sessizce yok sayılmıyor — v3 onu KELİME olarak okuyor (canlı rapor:
// uydurma `[slow]` etiketi cümlenin ortasında "slow" diye telaffuz edildi).
//
// Kılavuzda olup KASTEN dışarıda bırakılanlar: ses efektleri ([gunshot],
// [applause], [clapping], [explosion]), şarkı ([singing], [sings]), şaka
// etiketleri ([woo], [fart]) ve aksan etiketi ([strong X accent]).
export const V3_AUDIO_TAGS = [
  // Duygu / ton
  "happy", "sad", "excited", "angry", "annoyed", "appalled", "thoughtful",
  "surprised", "sarcastic", "curious", "crying", "mischievously",
  // Sözsüz sesler
  "laughs", "laughs harder", "starts laughing", "chuckles", "wheezing", "snorts",
  "sighs", "sighs harder", "exhales", "exhales sharply", "inhales deeply",
  "swallows", "gulps", "clears throat",
  // Aktarım / tempo
  "whispers", "short pause", "long pause",
] as const;

const ALLOWED = new Set<string>(V3_AUDIO_TAGS.map((t) => t.toLowerCase()));

export function isAllowedTag(inner: string): boolean {
  return ALLOWED.has(inner.trim().toLowerCase());
}

/// Tam metin üzerinde çalışan temizleyici (açılış repliği gibi stream
/// OLMAYAN yerler için). Bilinmeyen `[...]` blokları düşer, izinli olanlar
/// olduğu gibi kalır.
export function stripUnknownAudioTags(text: string): string {
  return text
    .replace(/\[([^\]\n]{1,40})\]/g, (whole, inner: string) => (isAllowedTag(inner) ? whole : " "))
    .replace(/\s{2,}/g, " ")
    .trim();
}

/// Parça parça gelen metin için durumlu temizleyici.
///
/// Stream'de bir etiket İKİ ayrı chunk'a bölünebilir ("...[wh" + "ispers] ..."),
/// bu yüzden metni olduğu gibi tek tek süzmek yetmiyor: açılmış bir `[`
/// görüldüğünde kapanışı gelene kadar o kısım TUTULUR, sonra izinliyse aynen,
/// değilse silinerek bırakılır.
///
/// Bekleme sınırsız değil: `MAX_HOLD` karakterden sonra kapanış gelmediyse
/// tutulan metin olduğu gibi salınır. Aksi halde model düz metinde tek bir `[`
/// yazdığında cevabın geri kalanı sonsuza kadar tutulur ve arama sessiz kalırdı.
const MAX_HOLD = 48;

export interface StreamTagSanitizer {
  /// Yeni parçayı işler, GÖNDERİLEBİLİR metni döndürür ("" olabilir).
  push(chunk: string): string;
  /// Stream bittiğinde tutulan artığı bırakır.
  flush(): string;
}

export function createStreamTagSanitizer(): StreamTagSanitizer {
  // Açık `[`den sonrası burada birikir; boşsa tutulan bir şey yok.
  let held = "";

  function drainHeld(): string {
    // Kapanış gelmedi ve sabır bitti: ham haliyle bırak. Uydurma etiketten
    // daha kötüsü, sesin komple kaybolmasıdır.
    const out = held;
    held = "";
    return out;
  }

  return {
    push(chunk: string): string {
      let out = "";
      for (const ch of chunk) {
        if (held) {
          held += ch;
          if (ch === "]") {
            const inner = held.slice(1, -1);
            out += isAllowedTag(inner) ? held : "";
            held = "";
          } else if (held.length > MAX_HOLD) {
            out += drainHeld();
          }
          continue;
        }
        if (ch === "[") {
          held = "[";
          continue;
        }
        out += ch;
      }
      return out;
    },
    flush(): string {
      return held ? drainHeld() : "";
    },
  };
}
