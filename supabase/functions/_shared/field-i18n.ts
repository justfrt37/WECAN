// supabase/functions/_shared/field-i18n.ts
//
// Character taglines, professions, and interests are always authored in
// ENGLISH (see the bio-generation prompt in create-character/index.ts)
// but the app's UI ships in 7 languages
// (Plumm/Localizable.xcstrings, mirrored by ConversationLanguage.supported
// in the client — though only en/tr are fully maintained today, see
// Plumm/Services/AppLanguage.swift). This translates all three fields once
// at write time into every supported locale so the client can pick the
// right one.
//
// Replaces the old tagline-only tagline-i18n.ts (source language flipped
// from tr to en when the character-data language cleanup shipped).
//
// Keep SUPPORTED_LOCALES in sync with Plumm/Services/ConversationLanguage.swift.

const SUPPORTED_LOCALES = ["en", "tr", "de", "es", "fr", "it", "pt"] as const;

const XAI_URL = "https://api.x.ai/v1/chat/completions";
const MODEL = "grok-4.3";

export interface CharacterFields {
  tagline: string;
  profession?: string;
  interests: string[];
}

export interface TranslatedFields {
  tagline: Record<string, string>;
  profession: Record<string, string>;
  interests: Record<string, string[]>;
}

/// Translates a character's tagline + profession + interests from English
/// into every other supported locale, in a single LLM call. Returns maps
/// that always include the original `en` entry. Throws on LLM/parse
/// failure — callers should catch and fall back to `{ en: <original> }` so
/// character creation never blocks on translation.
export async function translateCharacterFields(
  fields: CharacterFields,
  xaiApiKey: string,
): Promise<TranslatedFields> {
  const targets = SUPPORTED_LOCALES.filter((locale) => locale !== "en");
  const interestsList = fields.interests.map((i) => `"${i}"`).join(", ");
  const prompt =
    `Translate this AI companion's profile fields from English into ${targets.join(", ")}. ` +
    `Keep the same warm, first-person tone and roughly the same length for the tagline. ` +
    `Keep every emoji exactly as-is in profession and interests, translate only the text after it. ` +
    `Keep the interests array the same length and order as the original, one translation per item — ` +
    `no quotes, no explanation, no extra commentary.\n` +
    `Return ONLY a JSON object shaped like: ` +
    `{${targets.map((l) => `"${l}":{"tagline":"...","profession":"...","interests":["...","..."]}`).join(",")}}\n\n` +
    `Tagline (en): ${fields.tagline}\n` +
    `Profession (en): ${fields.profession ?? ""}\n` +
    `Interests (en): [${interestsList}]`;

  const r = await fetch(XAI_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${xaiApiKey}` },
    body: JSON.stringify({
      model: MODEL,
      messages: [{ role: "user", content: prompt }],
      temperature: 0.3,
      max_tokens: 1500,
    }),
  });
  if (!r.ok) throw new Error(`LLM ${r.status}: ${await r.text()}`);
  const d = await r.json();
  const raw: string = d?.choices?.[0]?.message?.content ?? "{}";
  const jsonMatch = raw.match(/\{[\s\S]*\}/);
  const parsed = JSON.parse(jsonMatch ? jsonMatch[0] : raw);

  const tagline: Record<string, string> = { en: fields.tagline };
  const profession: Record<string, string> = fields.profession ? { en: fields.profession } : {};
  const interests: Record<string, string[]> = { en: fields.interests };

  for (const locale of targets) {
    const entry = parsed[locale];
    if (!entry || typeof entry !== "object") continue;
    if (typeof entry.tagline === "string" && entry.tagline.trim()) {
      tagline[locale] = entry.tagline.trim();
    }
    if (fields.profession && typeof entry.profession === "string" && entry.profession.trim()) {
      profession[locale] = entry.profession.trim();
    }
    if (Array.isArray(entry.interests) && entry.interests.length === fields.interests.length) {
      interests[locale] = entry.interests.map((s: unknown) => String(s).trim());
    }
  }
  return { tagline, profession, interests };
}
