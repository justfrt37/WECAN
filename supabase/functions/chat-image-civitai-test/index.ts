// supabase/functions/chat-image-civitai-test/index.ts
//
// TEST-ONLY sibling of chat-image: identical prompt-composition mechanic
// (Grok text model writes the six-field photo-director prompt), but the
// actual image generation call is swapped from xAI Grok Imagine to Civitai's
// orchestration API (Flux2 Klein — same engine/model used for both SFW and,
// once membership/mature-content is enabled, NSFW).
//
// No token charging, no DB writes, no auth requirement — just generates and
// returns { url, prompt } so a standalone test page can render it.
//
//   İstek:  { characterAppearance, characterCategory, prompt, baselineImageUrl? }
//   Cevap:  { url, composedPrompt }  veya  { error }

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const XAI_API_KEY = Deno.env.get("XAI_API_KEY") ?? "";
const XAI_CHAT_URL = "https://api.x.ai/v1/chat/completions";
const TEXT_MODEL = "grok-4-1-fast-non-reasoning";

const CIVITAI_API_TOKEN = Deno.env.get("CIVITAI_API") ?? "";
// Test-only shared secret — this function has no JWT check and no token
// charging, so without this anyone who finds the URL could burn Buzz/XAI
// credits generating arbitrary images for free. Set TEST_SHARED_SECRET in
// Supabase secrets and pass the same value as the "x-test-secret" header.
const TEST_SHARED_SECRET = Deno.env.get("TEST_SHARED_SECRET") ?? "";
const CIVITAI_ORCHESTRATION_URL = "https://orchestration.civitai.com/v2/consumer/workflows?wait=60";
const CIVITAI_ENGINE = "flux2";
const CIVITAI_MODEL = "klein";
const CIVITAI_MODEL_VERSION = "4b";
const IMAGE_WIDTH = 1024;
const IMAGE_HEIGHT = 1024;

const NO_TEXT_RULE =
  "The image must contain absolutely no text, letters, numbers, captions, " +
  "subtitles, watermarks, logos, or writing of any kind anywhere in the frame.";

const FIELD_FORMAT_EXAMPLE =
  "CAMERA DETAILS: Shot on disposable camera, direct flash, on-camera flash " +
  "harsh lighting, visible grain, slight red-eye effect, overexposed highlights\n" +
  "LIGHTING: Flash illuminating subject sharply against a darker room\n" +
  "SUBJECT: 22 year old woman, long wavy dark hair, minimal makeup, relaxed " +
  "expression\n" +
  "OUTFIT: Oversized band t-shirt, shorts, barefoot\n" +
  "POSE: Sitting cross-legged on bedroom floor, looking directly at camera, " +
  "leaning slightly forward\n" +
  "LOCATION: Bedroom at night, messy bed in background, clothes on chair";

function realisticFieldGuidance(): string {
  return (
    "CAMERA DETAILS: default to \"Shot on iPhone 17 Pro Max\" unless the mood " +
    "calls for something else. Always state realistic sensor characteristics: " +
    "visible grain/noise appropriate to the lighting, and whether an " +
    "on-camera flash is used.\n" +
    "LIGHTING: the specific light source and quality matching the scene, " +
    "with natural true-to-life color — never oversaturated or neon.\n" +
    "SUBJECT: the character's appearance (given below), plus natural skin " +
    "texture with visible pores and subtle imperfections — NEVER \"plastic,\" " +
    "\"airbrushed,\" \"waxy,\" \"over-smoothed,\" or \"AI-generated\" looking " +
    "skin.\n" +
    "OUTFIT: exactly what the character is wearing, specific enough to " +
    "visualize.\n" +
    "POSE: exactly how the character is positioned.\n" +
    "LOCATION: the specific background and setting.\n"
  );
}

function baselineConsistencyNote(): string {
  return (
    "\nA baseline reference image of this exact character is separately " +
    "attached to the image generator for face/hair/character-design " +
    "consistency. THE FACE IS NON-NEGOTIABLE — it must be recognizably the " +
    "SAME PERSON as the reference. Never describe a different face, " +
    "hairstyle, or character design — only expression, outfit, pose, and " +
    "location may change per the user's request.\n"
  );
}

async function callGrokText(messages: { role: string; content: string }[], maxTokens: number): Promise<string> {
  const r = await fetch(XAI_CHAT_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${XAI_API_KEY}` },
    body: JSON.stringify({ model: TEXT_MODEL, messages, temperature: 0.8, max_tokens: maxTokens }),
  });
  if (!r.ok) throw new Error(`LLM ${r.status}: ${await r.text()}`);
  const d = await r.json();
  return d?.choices?.[0]?.message?.content ?? "";
}

async function composeImagePrompt(opts: {
  appearance: string;
  userPrompt: string;
  hasBaseline: boolean;
}): Promise<string> {
  const fieldGuidance = realisticFieldGuidance() + (opts.hasBaseline ? baselineConsistencyNote() : "");

  const systemPrompt =
    "You are a professional photo director writing the exact prompt that will be " +
    "fed into an AI image generator to produce ONE image of a specific character.\n\n" +
    `The character: ${opts.appearance}\n\n` +
    "YOU must make every creative decision yourself — never write a vague, " +
    "generic, or unspecified field. Every field below must contain concrete, " +
    "specific details.\n\n" +
    "PRIORITY RULE: if the user's request explicitly specifies a detail for any " +
    "field, use exactly what they specified. Only invent details for the " +
    "fields the user left unspecified.\n\n" +
    "Structure the final prompt using EXACTLY these six labeled fields, each on " +
    "its own line:\n\n" +
    fieldGuidance +
    `\n${NO_TEXT_RULE}\n\n` +
    "Calibration example of the required format (different photo, format " +
    "reference only):\n" +
    FIELD_FORMAT_EXAMPLE +
    "\n\nNow write the final prompt tailored to the user's request below. " +
    "Output ONLY the six labeled lines — no extra commentary, no quotes.\n\n" +
    `The user's request:\n"""\n${opts.userPrompt}\n"""`;

  const composed = await callGrokText(
    [
      { role: "system", content: systemPrompt },
      { role: "user", content: "Write the final image-generation prompt now." },
    ],
    500
  );
  const trimmed = composed.trim();
  return trimmed ? `${trimmed}\n${NO_TEXT_RULE}` : `${opts.userPrompt}\n${NO_TEXT_RULE}`;
}

async function civitaiGenerate(prompt: string, baselineImageUrl: string | null): Promise<string> {
  const input: Record<string, unknown> = {
    engine: CIVITAI_ENGINE,
    model: CIVITAI_MODEL,
    modelVersion: CIVITAI_MODEL_VERSION,
    prompt,
    width: IMAGE_WIDTH,
    height: IMAGE_HEIGHT,
    quantity: 1,
  };
  if (baselineImageUrl) {
    input.operation = "editImage";
    input.images = [baselineImageUrl];
  } else {
    input.operation = "createImage";
  }

  const r = await fetch(CIVITAI_ORCHESTRATION_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${CIVITAI_API_TOKEN}` },
    body: JSON.stringify({ steps: [{ $type: "imageGen", input }] }),
  });
  if (!r.ok) throw new Error(`Civitai ${r.status}: ${await r.text()}`);
  const d = await r.json();
  const img = d?.steps?.[0]?.output?.images?.[0];
  if (!img?.url) throw new Error(`Civitai: no image in response — ${JSON.stringify(d).slice(0, 500)}`);
  return img.url as string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    if (!TEST_SHARED_SECRET || req.headers.get("x-test-secret") !== TEST_SHARED_SECRET) {
      return json({ error: "unauthorized" }, 401);
    }
    if (!CIVITAI_API_TOKEN) return json({ error: "no_civitai_key" }, 500);

    const b = await req.json();
    const userPrompt: string = (b.prompt ?? "").toString().trim();
    const characterAppearance: string = (b.characterAppearance ?? "a young woman").toString();
    const baselineImageUrl: string | null = b.baselineImageUrl ? String(b.baselineImageUrl) : null;
    if (!userPrompt) return json({ error: "prompt required" }, 400);

    const composedPrompt = await composeImagePrompt({
      appearance: characterAppearance,
      userPrompt,
      hasBaseline: baselineImageUrl !== null,
    });

    const url = await civitaiGenerate(composedPrompt, baselineImageUrl);
    return json({ url, composedPrompt });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
