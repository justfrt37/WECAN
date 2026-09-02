// supabase/functions/_shared/elevenVoiceSettings.ts
//
// Static per-personality_role ElevenLabs TTS `stability` preset for voice
// calls (Flash v2.5, via the SDK's TTSOverrides — see
// docs/superpowers/specs/2026-07-29-voice-call-agents-migration-design.md).
// Lower stability = more emotional/prosodic variance between generations;
// higher = flatter, more consistent delivery. There is deliberately no
// `style` knob here — the SDK's TTSOverrides doesn't expose one.

// 2026-09-02, eleven_v3_conversational'a geçişle birlikte tek değere indi.
//
// SEBEP ÖLÇÜLDÜ: v3'te stability sürekli bir eksen DEĞİL. API 0.25/0.3/0.7
// gibi değerleri kabul ediyor (HTTP 200) ama kullanmıyor — sabit seed'le aynı
// cümle üretildiğinde 0.25, 0.3 ve 0.5 BİREBİR aynı uzunlukta ses veriyor
// (69.007 bayt), 0.0 ise 62.319, 1.0 ise 59.812. Yani sadece üç gerçek mod
// var: 0.0 Creative, 0.5 Natural, 1.0 Robust. Eski haritadaki 0.25/0.35/0.4/
// 0.65/0.7 değerlerinin BEŞİ de aynı moda (Natural) yuvarlanıyordu — yani rol
// başına farklılaştırma zaten hiç çalışmıyordu, sadece öyle sanıyorduk.
const STABILITY = 0.0; // Creative — ifade aralığı en geniş mod

export function stabilityFor(_role: string): number {
  return STABILITY;
}

// Stability jitter'ı KALDIRILDI (2026-09-02). İki sebeple:
//   1. İşe yaramıyordu. ±0.05'lik sapma v3'ün üç modu arasında zıplamıyor,
//      hep aynı moda yuvarlanıyordu (yukarıdaki ölçüme bakın).
//   2. Gerekli değil. Jitter'ın var oluş sebebi buradaki eski yorumun kendi
//      itirafıydı: "gerçek tur-içi varyans mimari olarak mümkün değil, bu
//      yüzden arama başında bir kez rastgele sapma uyguluyoruz" — yani
//      yapamadığımız şeyin taklidiydi. v3'te varyans artık GERÇEKTEN tur
//      içinde geliyor, çünkü model her cevapta ayrı [laughs]/[sighs]/
//      [whispers] koyabiliyor. Taklide gerek kalmadı.
// speed'te küçük sapma kaldı: konuşma hızı bir ifade kanalı değil, sadece
// arka arkaya aramaların birebir aynı tempoda olmamasını sağlıyor.
function jitter(base: number, spread: number, min: number, max: number): number {
  const value = base + (Math.random() * 2 - 1) * spread;
  return Math.min(max, Math.max(min, Math.round(value * 100) / 100));
}

export function callVoiceSettingsFor(role: string): { stability: number; speed: number } {
  return {
    stability: stabilityFor(role),
    speed: jitter(1.0, 0.06, 0.85, 1.15),
  };
}
