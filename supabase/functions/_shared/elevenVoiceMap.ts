// supabase/functions/voice-message-tts/elevenVoiceMap.ts
//
// 28 sesli-mesaj kombinasyonu (7 personality_role × 4 vibe) → ElevenLabs
// voice_id. eleven_v3 modeli tüm dilleri (74 dil) tek voice_id ile konuşabildiği
// için (bkz. docs.elevenlabs.io), Google Chirp3-HD haritasının aksine dil
// başına ayrı liste gerekmiyor — VOICE_MAP tek başına 7 dilin hepsini kapsıyor.
// Sesler kullanıcının ElevenLabs "My Voices" listesinden seçildi (2026-07).

const VOICE_MAP: Record<string, string> = {
  // flirty
  "flirty_Sweet": "6j8uSqQkZH2WrWDVIiRB", // Luna - Late Night Sweetheart
  "flirty_Mysterious": "eVItLK1UvXctxuaRV2Oq", // Jean - Alluring and Playful Femme Fatale
  "flirty_Energetic": "n7Wi4g1bhpw4Bs8HK5ph", // Gigi - Cute, Peppy, Energetic
  "flirty_Elegant": "YgzytRZyVmEux6PCtJYB", // Ivanna - Sultry, Fun and Captivating
  // distant
  "distant_Sweet": "QDBL6ATWz3YtwddGAE6E", // Emma - Fresh, Calm and Soft
  "distant_Mysterious": "Qbw4VpyUrHEG7NigKzty", // Kristen – Cold Evil Queen Villain
  "distant_Energetic": "PFqo8D2UY6vd5tzJUrsl", // Miss B. - Inspirational, Authoritative, Confident
  "distant_Elegant": "e6qsVnCuD0MWxmhZcuKz", // Mia - Elegant Storyteller
  // shy
  "shy_Sweet": "m0MqfGOWTAfVVEaz4KxX", // Alexandra
  "shy_Mysterious": "wQ7dVQFxIqwokkwsMqqn", // Neslihan – Psychology & Mind-Focused
  "shy_Energetic": "cgSgspJ2msm6clMCkdW9", // Jessica - Playful, Bright, Warm
  "shy_Elegant": "Xb7hH8MSUJpSbSDYk0k2", // Alice - Clear, Engaging Educator
  // playful
  "playful_Sweet": "Nggzl2QAXh3OijoXD116", // Candy - Young and Sweet
  "playful_Mysterious": "WLjZnm4PkNmYtNCyiCq8", // Lisa - Youthfull, Fun and Witty
  "playful_Energetic": "xctasy8XvGp2cVO9HL9k", // Allison - Energetic, Clear and Bubbly
  "playful_Elegant": "YZHSTqsq1isdXNsFLzBw", // Olivia - Smooth, charming, persuasive
  // devoted
  "devoted_Sweet": "4uXpMV2FG1JKkCQKIdSH", // Meshell - Warm Loving Calm
  "devoted_Mysterious": "tSFrmifcoKA2lXImR5MW", // Iris - Warm, Intimate & Narrative
  "devoted_Energetic": "ITRml9f5K7moz24wRnmV", // Cass - Warm & Energetic British Woman
  "devoted_Elegant": "LtYRTlMfWU5Q6Me90AIR", // Lily D - Clear, Calm, Expressive
  // crazy
  "crazy_Sweet": "eaNNqnkhfRYVtX7U7VLj", // Clara - Emotional, Dramatic and Polished
  "crazy_Mysterious": "sssn4wp3AspuK2kvy3Ym", // Vivien - Mysterious Witch
  "crazy_Energetic": "rdEILoSxdT6xKDZ56abJ", // Isla Wilde
  "crazy_Elegant": "pFZP5JQG7iQjIQuC4Bku", // Lily - Velvety Actress
  // ex
  "ex_Sweet": "8quEMRkSpwEaWBzHvTLv", // Veda Sky - Cozy Late Night Storyteller
  "ex_Mysterious": "SAz9YHcvj6GT2YYXdXww", // River - Relaxed, Neutral, Informative
  "ex_Energetic": "FGY2WhTYpPnrIDTdsKH5", // Laura - Enthusiast, Quirky Attitude
  "ex_Elegant": "EXAVITQu4vr4xnSDxMaL", // Sarah - Mature, Reassuring, Confident
};

const DEFAULT_VOICE_ID = "6j8uSqQkZH2WrWDVIiRB"; // Luna

export function elevenVoiceIdFor(role: string, vibe: string): string {
  return VOICE_MAP[`${role}_${vibe}`] ?? DEFAULT_VOICE_ID;
}
