// supabase/functions/_shared/elevenVoiceSettings.ts
//
// Static per-personality_role ElevenLabs TTS `stability` preset for voice
// calls (Flash v2.5, via the SDK's TTSOverrides — see
// docs/superpowers/specs/2026-07-29-voice-call-agents-migration-design.md).
// Lower stability = more emotional/prosodic variance between generations;
// higher = flatter, more consistent delivery. There is deliberately no
// `style` knob here — the SDK's TTSOverrides doesn't expose one.

const STABILITY_MAP: Record<string, number> = {
  crazy: 0.25,
  flirty: 0.35,
  playful: 0.35,
  devoted: 0.5,
  ex: 0.5,
  shy: 0.65,
  distant: 0.7,
};

const DEFAULT_STABILITY = 0.4;

export function stabilityFor(role: string): number {
  return STABILITY_MAP[role] ?? DEFAULT_STABILITY;
}

// TTSOverrides are set ONCE per call (custom-LLM webhook only streams
// text — no per-reply voice_settings channel exists in that contract, so
// true per-TURN variance isn't architecturally possible here). This is the
// honest achievable version: small random jitter applied once at call
// start, so back-to-back calls with the same character don't sound
// identically flat — not "changes mid-call," just "not robotically fixed
// call after call."
function jitter(base: number, spread: number, min: number, max: number): number {
  const value = base + (Math.random() * 2 - 1) * spread;
  return Math.min(max, Math.max(min, Math.round(value * 100) / 100));
}

export function callVoiceSettingsFor(role: string): { stability: number; speed: number } {
  return {
    stability: jitter(stabilityFor(role), 0.05, 0.05, 0.95),
    speed: jitter(1.0, 0.06, 0.85, 1.15),
  };
}
