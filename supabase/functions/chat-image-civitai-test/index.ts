// supabase/functions/chat-image-civitai-test/index.ts
//
// TEST-ONLY sibling of chat-image: prompt composition is a COPY of
// chat-image/index.ts's composeImagePrompt pipeline (same field guidance,
// same FRAMING_RULE/NO_TEXT_RULE, same category-based realistic/styled
// branch, same appearance/conversation/current-activity context builders) —
// kept byte-for-byte identical on purpose so this test never drifts from
// what production actually sends. Only the image-generation backend is
// fixed to Civitai's Flux2 Klein (same engine/model/dimensions chat-image
// uses via USE_CIVITAI_FOR_TESTING).
//
// No token charging, no DB writes, no auth requirement (besides the shared
// test secret) — just generates and returns { url, composedPrompt } so a
// standalone test page/script can render it.
//
//   İstek:  { characterName, profession?, tagline?, builderSelections?,
//             category?, prompt, history?, summary?, currentActivity?,
//             baselineImageUrl? }
//   Cevap:  { url, composedPrompt }  veya  { error }

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const XAI_API_KEY = Deno.env.get("XAI_API_KEY") ?? "";
const XAI_CHAT_URL = "https://api.x.ai/v1/chat/completions";
const TEXT_MODEL = "grok-4-1-fast-non-reasoning";

const CIVITAI_API_TOKEN = Deno.env.get("CIVITAI_API") ?? "";
const CIVITAI_ORCHESTRATION_URL = "https://orchestration.civitai.com/v2/consumer/workflows?wait=60";
// Flux1 Kontext (dev) — purpose-built identity-preserving edit model (per
// Civitai's own OpenAPI schema, this is the only image-gen input that takes
// a reference `images` array with a real editing objective; SDXL/Flux2
// Klein only expose `createVariant`/`editImage` with a strength dial, which
// is what caused face-drift in prior testing — see architecture_civitai
// memory). Native aspect ratios, no separate width/height.
const CIVITAI_ENGINE = "flux1-kontext";
const CIVITAI_MODEL = "dev";
const CIVITAI_ASPECT_RATIO = "9:16";
// Schema-enforced hard cap on Flux1Kontext's `prompt` field (1000 chars) —
// our six-field composed prompt can run ~1100 chars, so it must be clamped
// before being sent (the full text is still returned to the caller/logs).
const KONTEXT_PROMPT_MAX_LEN = 1000;

// Optional test-only alternate backends — pass body.engine = "sdxl" or "pony"
// to route through a self-hosted sdcpp checkpoint instead of Kontext. Both
// are SDXL-architecture (Pony's AIR ecosystem is "sdxl" too — no dedicated
// "pony" ecosystem exists in Civitai's schema), self-hosted (not BFL-managed
// like Kontext), so — per Flux2 Klein/RealVisXL precedent — expected to have
// no content moderation, unlike Kontext's silent-sanitize behavior. No
// identity mechanism (no baseline/LoRA) on either.
const SDXL_MODEL_URN = "urn:air:sdxl:checkpoint:civitai:1584358@3062969"; // Ultra Realistic (Illustrious) — quality/plasticity test
const PONY_MODEL_URN = "urn:air:sdxl:checkpoint:civitai:257749@290640"; // Pony Diffusion V6 XL — NSFW-capability test
const SDXL_WIDTH = 832;
const SDXL_HEIGHT = 1216;

interface BuilderSelections {
  category?: string;
  hairstyle?: string;
  hair_color?: string;
  eye_shape?: string;
  eye_color?: string;
  nose_shape?: string;
  skin_tone?: string;
  body_type?: string;
}

const NO_TEXT_RULE =
  "The image must contain absolutely no text, letters, numbers, captions, " +
  "subtitles, watermarks, logos, or writing of any kind anywhere in the frame.";

const FRAMING_RULE =
  "The output canvas is a TALL VERTICAL 9:16 frame (like a phone photo/story). " +
  "Compose for that shape: leave natural headroom above the subject's head, " +
  "and choose a pose/crop (e.g. waist-up, three-quarter, or full-body) that " +
  "fits the vertical frame comfortably. Never awkwardly clip background " +
  "objects (ceiling lights, door frames, furniture, signs) right at the edge " +
  "of the frame — either include them fully or leave them out of the shot.";

function appearanceContext(opts: {
  name: string;
  profession: string | null;
  tagline: string | null;
  builderSelections: BuilderSelections | null;
}): string {
  const bs = opts.builderSelections;
  const bodyType = bs?.body_type ? `, ${bs.body_type.toLowerCase()} body type` : "";
  const base = (bs && (bs.hairstyle || bs.hair_color || bs.eye_shape || bs.eye_color))
    ? `${opts.name}, a person with ${(bs.hairstyle ?? "").toLowerCase()} ` +
      `${(bs.hair_color ?? "").toLowerCase()} hair, ${(bs.eye_shape ?? "").toLowerCase()} ` +
      `${(bs.eye_color ?? "").toLowerCase()} eyes, ${(bs.nose_shape ?? "").toLowerCase()} nose, ` +
      `${(bs.skin_tone ?? "").toLowerCase()} skin tone${bodyType}`
    : `${opts.name}${opts.profession ? `, a ${opts.profession.toLowerCase()}` : ""}`;
  return opts.tagline ? `${base}. Bio: ${opts.tagline}` : base;
}

function stripVoiceTags(text: string): string {
  return text.replace(/\[[^\]]*\]/g, "").replace(/[ \t]{2,}/g, " ").trim();
}

function conversationContext(history: { role: string; content: string }[], summary: string | null): string {
  const parts: string[] = [];
  if (summary && summary.trim()) parts.push(stripVoiceTags(summary));
  if (history.length > 0) {
    parts.push(history.slice(-12).map((m) => `${m.role === "user" ? "User" : "Character"}: ${stripVoiceTags(m.content)}`).join("\n"));
  }
  if (parts.length === 0) return "";
  return (
    "\n\nCONTEXT FROM THIS CONVERSATION (use this for any established facts " +
    "about the character's life — job, workplace, ongoing storyline, etc. — " +
    "but the user's request below still takes priority for what to actually " +
    "depict):\n" + parts.join("\n\n")
  );
}

function currentActivityContext(currentActivity: string | null): string {
  if (!currentActivity || !currentActivity.trim()) return "";
  return (
    "\n\nCHARACTER'S CURRENT REAL-TIME SITUATION — reflect this in LOCATION/" +
    "POSE/OUTFIT unless the user's request explicitly specifies otherwise " +
    "(this is what the character is ACTUALLY doing right now, takes " +
    "priority over generic profession-based assumptions): " + currentActivity.trim()
  );
}

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

function baselineConsistencyNote(): string {
  return (
    "\nA baseline reference image of this exact character is separately " +
    "attached to the image generator (you cannot see it, but it will be used " +
    "for face/hair/character-design consistency). THE FACE IS NON-NEGOTIABLE " +
    "— it must be recognizably the SAME PERSON as the reference: same face " +
    "shape, same bone structure, same freckles/moles/distinguishing marks, " +
    "same exact face. Never describe a different face, hairstyle, or " +
    "character design than what's implied above — only the expression, " +
    "outfit, pose, and location may change per the user's request.\n"
  );
}

function realisticFieldGuidance(): string {
  return (
    "CAMERA DETAILS: default to \"Shot on iPhone 17 Pro Max\" unless the mood " +
    "calls for something else (e.g. a disposable camera with direct on-camera " +
    "flash, harsh lighting, visible grain, slight red-eye, overexposed " +
    "highlights, for a raw candid night photo). Always state realistic sensor " +
    "characteristics: visible grain/noise appropriate to the lighting, and " +
    "whether an on-camera flash is used.\n" +
    "LIGHTING: the specific light source and quality (soft window daylight, " +
    "golden hour, harsh direct flash, warm indoor lamp, overcast, candlelight, " +
    "etc.) matching the scene, with natural true-to-life color — never " +
    "oversaturated or neon.\n" +
    "SUBJECT: the character's appearance (given below), plus natural skin " +
    "texture with visible pores and subtle imperfections — NEVER \"plastic,\" " +
    "\"airbrushed,\" \"waxy,\" \"over-smoothed,\" or \"AI-generated\" looking " +
    "skin. EXPRESSION MUST MATCH THE MOOD OF THIS SPECIFIC PHOTO, not the " +
    "character's default/profile-picture smile — a baseline reference photo " +
    "showing her smiling does NOT mean every photo should smile. Choose " +
    "whatever expression a real person would actually have for this exact " +
    "moment/pose/outfit/request (e.g. a smoldering, half-lidded, or serious/" +
    "sultry look for something intimate or a thirst-trap-style photo; a " +
    "genuine laugh for something silly; a soft neutral look for something " +
    "candid) — reason it out per the specific photo, never default to " +
    "smiling out of habit.\n" +
    "OUTFIT: exactly what the character is wearing, specific enough to " +
    "visualize (garment type, fit, color) — infer something fitting if the " +
    "user didn't specify.\n" +
    "POSE: exactly how the character is positioned — where their arms and legs " +
    "are, their posture, what they're looking at.\n" +
    "LOCATION: the specific background and setting — be concrete about what's " +
    "visible around the character. If the user's request is generic (e.g. " +
    "\"her workplace\", \"where she works\"), infer the SPECIFIC real-world " +
    "setting implied by the character's actual profession/bio/conversation " +
    "context below (a scientist's workplace is a lab, not a generic office; a " +
    "chef's workplace is a kitchen; a musician's workplace is a studio or " +
    "stage) — never default to a generic corporate office unless that's " +
    "genuinely what fits.\n"
  );
}

function styledFieldGuidance(): string {
  return (
    "CAMERA DETAILS: this is a STYLIZED/ILLUSTRATED (non-photorealistic) " +
    "character — choose whichever illustrated art style best fits the " +
    "character and the user's request (e.g. anime/cel-shaded illustration, " +
    "fantasy digital painting, sci-fi digital art, or another fitting " +
    "illustrated style), and name that exact style and rendering technique " +
    "explicitly instead of a camera/phone.\n" +
    "LIGHTING: the specific light source, quality, and overall color palette " +
    "matching the scene and art style.\n" +
    "SUBJECT: the character's appearance (given below). EXPRESSION MUST MATCH " +
    "THE MOOD OF THIS SPECIFIC PHOTO, not the character's default/profile-" +
    "picture smile — a baseline reference showing her smiling does NOT mean " +
    "every photo should smile. Choose whatever expression actually fits this " +
    "exact moment/pose/outfit/request (e.g. smoldering/half-lidded/serious " +
    "for something intimate or a thirst-trap-style photo, a genuine laugh for " +
    "something silly, soft/neutral for something candid) — never default to " +
    "smiling out of habit.\n" +
    "OUTFIT: exactly what the character is wearing, specific enough to " +
    "visualize — infer something fitting if the user didn't specify.\n" +
    "POSE: exactly how the character is positioned — where their arms and legs " +
    "are, their posture, what they're looking at.\n" +
    "LOCATION: the specific background and setting.\n"
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
  category: string;
  userPrompt: string;
  hasBaseline: boolean;
  context: string;
}): Promise<string> {
  const isRealistic = opts.category !== "Fictional";
  const fieldGuidance =
    (isRealistic ? realisticFieldGuidance() : styledFieldGuidance()) +
    (opts.hasBaseline ? baselineConsistencyNote() : "");

  const systemPrompt =
    "You are a professional photo director writing the exact prompt that will be " +
    "fed into an AI image generator to produce ONE image of a specific character.\n\n" +
    `The character: ${opts.appearance}${opts.context}\n\n` +
    "YOU must make every creative decision yourself — never write a vague, " +
    "generic, or unspecified field, and never leave anything for the image " +
    "generator to infer or guess. Every field below must contain concrete, " +
    "specific details, exactly as concrete as the calibration example further " +
    "down.\n\n" +
    "PRIORITY RULE: if the user's request explicitly specifies a detail for any " +
    "field (an exact outfit, pose, location, camera/lighting style, etc.), use " +
    "exactly what they specified for that field — do not change, substitute, or " +
    "reinterpret it. Only invent details for the fields (or parts of fields) the " +
    "user left unspecified.\n\n" +
    "Structure the final prompt using EXACTLY these six labeled fields, each on " +
    "its own line, each followed by short comma-separated descriptive phrases " +
    "(not full sentences):\n\n" +
    fieldGuidance +
    "\nAspect ratio and resolution are already fixed elsewhere by the caller — " +
    `do not mention them in any field. ${NO_TEXT_RULE} ${FRAMING_RULE}\n\n` +
    "Calibration example of the required format and level of specificity " +
    "(different photo, for format reference only — do not reuse its content):\n" +
    FIELD_FORMAT_EXAMPLE +
    "\n\nNow evaluate the user's request below and write the final prompt in " +
    "this exact six-field format, tailored specifically to what they asked for. " +
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

async function civitaiPollUntilDone(workflowId: string): Promise<Record<string, unknown>> {
  for (let i = 0; i < 10; i++) {
    await new Promise((res) => setTimeout(res, 6000));
    const r = await fetch(`https://orchestration.civitai.com/v2/consumer/workflows/${workflowId}`, {
      headers: { Authorization: `Bearer ${CIVITAI_API_TOKEN}` },
    });
    if (!r.ok) throw new Error(`Civitai poll ${r.status}: ${await r.text()}`);
    const d = await r.json();
    if (d.status === "succeeded" || d.status === "failed") return d;
  }
  throw new Error("Civitai poll timed out");
}

async function civitaiGenerate(prompt: string, baselineImageUrl: string | null, engineOverride: string | null, variantStrength: number): Promise<string> {
  let input: Record<string, unknown>;
  if (engineOverride === "sdxl" || engineOverride === "pony") {
    const modelUrn = engineOverride === "pony" ? PONY_MODEL_URN : SDXL_MODEL_URN;
    input = baselineImageUrl
      ? {
          engine: "sdcpp",
          ecosystem: "sdxl",
          operation: "createVariant",
          model: modelUrn,
          prompt,
          width: SDXL_WIDTH,
          height: SDXL_HEIGHT,
          steps: 28,
          cfgScale: 5,
          image: baselineImageUrl,
          strength: variantStrength,
          quantity: 1,
        }
      : {
          engine: "sdcpp",
          ecosystem: "sdxl",
          operation: "createImage",
          model: modelUrn,
          prompt,
          width: SDXL_WIDTH,
          height: SDXL_HEIGHT,
          steps: 28,
          cfgScale: 5,
          quantity: 1,
        };
  } else {
    const clampedPrompt = prompt.length > KONTEXT_PROMPT_MAX_LEN ? prompt.slice(0, KONTEXT_PROMPT_MAX_LEN) : prompt;
    input = {
      engine: CIVITAI_ENGINE,
      model: CIVITAI_MODEL,
      prompt: clampedPrompt,
      aspectRatio: CIVITAI_ASPECT_RATIO,
      quantity: 1,
      ...(baselineImageUrl ? { images: [baselineImageUrl] } : {}),
    };
  }

  const r = await fetch(CIVITAI_ORCHESTRATION_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${CIVITAI_API_TOKEN}` },
    body: JSON.stringify({ steps: [{ $type: "imageGen", input }] }),
  });
  if (!r.ok) throw new Error(`Civitai ${r.status}: ${await r.text()}`);
  let d = await r.json();
  // Civitai returns several in-flight statuses (seen: "preparing", "processing")
  // before "succeeded"/"failed" — poll on anything that isn't a terminal state.
  if (d.status !== "succeeded" && d.status !== "failed" && d.id) d = await civitaiPollUntilDone(d.id);
  if (d.status !== "succeeded") throw new Error(`Civitai job failed: ${JSON.stringify(d).slice(0, 500)}`);

  const imgUrl = (d as any)?.steps?.[0]?.output?.images?.[0]?.url;
  if (!imgUrl) throw new Error(`Civitai: no image url in response — ${JSON.stringify(d).slice(0, 500)}`);
  return imgUrl as string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    if (!CIVITAI_API_TOKEN) return json({ error: "no_civitai_key" }, 500);

    const b = await req.json();
    const userPrompt: string = (b.prompt ?? "").toString().trim();
    if (!userPrompt) return json({ error: "prompt required" }, 400);

    const characterName: string = (b.characterName ?? "a young woman").toString();
    const profession: string | null = typeof b.profession === "string" ? b.profession : null;
    const tagline: string | null = typeof b.tagline === "string" ? b.tagline : null;
    const builderSelections: BuilderSelections | null = b.builderSelections ?? null;
    const category: string = (b.category ?? "Realistic").toString();
    const history: { role: string; content: string }[] = Array.isArray(b.history) ? b.history : [];
    const summary: string | null = typeof b.summary === "string" ? b.summary : null;
    const currentActivity: string | null = typeof b.currentActivity === "string" ? b.currentActivity : null;
    const baselineImageUrl: string | null = b.baselineImageUrl ? String(b.baselineImageUrl) : null;
    const engineOverride: string | null = typeof b.engine === "string" ? b.engine : null;
    const variantStrength: number = typeof b.strength === "number" ? b.strength : 0.65;
    // Test-only bypass — when set, skips Grok prompt composition entirely and
    // sends this string to Civitai as-is. Needed to test Pony-style checkpoints
    // with their expected Danbooru-tag format instead of the six-field
    // natural-language prompt the real pipeline writes.
    const rawPrompt: string | null = typeof b.rawPrompt === "string" ? b.rawPrompt : null;

    const composedPrompt = rawPrompt ?? await composeImagePrompt({
      appearance: appearanceContext({ name: characterName, profession, tagline, builderSelections }),
      category,
      userPrompt,
      hasBaseline: baselineImageUrl !== null,
      context: conversationContext(history, summary) + currentActivityContext(currentActivity),
    });

    const url = await civitaiGenerate(composedPrompt, baselineImageUrl, engineOverride, variantStrength);
    return json({ url, composedPrompt });
  } catch (e) {
    console.error(String(e));
    return json({ error: String(e) }, 500);
  }
});
