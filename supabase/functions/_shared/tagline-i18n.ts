// supabase/functions/_shared/tagline-i18n.ts
//
// Character taglines are always authored in Turkish (see the bio-generation
// prompts in create-character/dev-create-character) but the app's UI ships
// in 7 languages (aiGirlfriend/Localizable.xcstrings, mirrored by
// ConversationLanguage.supported in the client). Before this, the tagline
// column was plain text — every user saw the same Turkish line regardless
// of their locale. This translates it once at write time into every
// supported locale so the client can pick the right one.
//
// Keep SUPPORTED_LOCALES in sync with aiGirlfriend/Services/ConversationLanguage.swift.

const SUPPORTED_LOCALES = ["tr", "en", "de", "es", "fr", "it", "pt"] as const;

const XAI_URL = "https://api.x.ai/v1/chat/completions";
const MODEL = "grok-4-1-fast-non-reasoning";

/// Translates a Turkish tagline into every other supported locale.
/// Returns a locale -> text map that always includes the original `tr` entry.
/// Throws on LLM/parse failure — callers should catch and fall back to
/// `{ tr: bio }` so character creation never blocks on translation.
export async function translateTagline(bio: string, xaiApiKey: string): Promise<Record<string, string>> {
  const targets = SUPPORTED_LOCALES.filter((locale) => locale !== "tr");
  const prompt =
    `Translate this AI companion's tagline from Turkish into ${targets.join(", ")}. ` +
    `Keep the same warm, first-person tone, emoji, and roughly the same length in each language — ` +
    `no quotes, no explanation, no extra commentary.\n` +
    `Return ONLY a JSON object with one key per language code: ` +
    `{${targets.map((locale) => `"${locale}":"..."`).join(",")}}\n\n` +
    `Tagline (tr): ${bio}`;

  const r = await fetch(XAI_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${xaiApiKey}` },
    body: JSON.stringify({
      model: MODEL,
      messages: [{ role: "user", content: prompt }],
      temperature: 0.3,
      max_tokens: 500,
    }),
  });
  if (!r.ok) throw new Error(`LLM ${r.status}: ${await r.text()}`);
  const d = await r.json();
  const raw: string = d?.choices?.[0]?.message?.content ?? "{}";
  const jsonMatch = raw.match(/\{[\s\S]*\}/);
  const parsed = JSON.parse(jsonMatch ? jsonMatch[0] : raw);

  const result: Record<string, string> = { tr: bio };
  for (const locale of targets) {
    if (typeof parsed[locale] === "string" && parsed[locale].trim()) {
      result[locale] = parsed[locale].trim();
    }
  }
  return result;
}
