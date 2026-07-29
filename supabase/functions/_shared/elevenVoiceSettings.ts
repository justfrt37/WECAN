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
