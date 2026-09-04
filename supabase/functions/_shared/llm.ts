// Tek LLM giriş noktası. 2026-09-02'ye kadar on ayrı fonksiyon kendi fetch'ini
// kendi yazıyordu ve hepsi doğrudan xAI'ye gidiyordu; sağlayıcı değiştirmek on
// yerde aynı düzenlemeyi yapmak demekti. Artık tek yer.
//
// Birincil model DeepSeek. Gerekçe ölçüm: 18 turluk +18 testinde eşit ya da
// daha iyi kaliteyle ~16x daha ucuz, ve sürekli açık sohbette Grok aynı emir
// bloğunu tekrarlamaya kilitlenirken DeepSeek sohbette kalıyor
// (plumm_nsfw_testi.md). Türkçede tokenizer'ı da daha verimli: aynı
// sınıflandırıcı promptu Grok'ta 272, DeepSeek'te 99 giriş tokeni.
//
// xAI SİLİNMEDİ, iki sebeple:
//   1. GÖRÜ. deepseek-chat metin-only, görsel içeren istek xAI'ye gitmek
//      zorunda yoksa özellik komple kırılır.
//   2. YEDEK. Tek sağlayıcı kesintisi tüm uygulamayı düşürürdü.
// Görsel ÜRETİMİ (images/generations, images/edits) bu modülün kapsamında
// değil — DeepSeek'te karşılığı yok, çağıran fonksiyonlarda xAI'de kalıyor.

const XAI_API_KEY = Deno.env.get("XAI_API_KEY") ?? "";
const XAI_URL = "https://api.x.ai/v1/chat/completions";
const XAI_MODEL = "grok-4.3";

// "deepseek-chat", DeepSeek'in kendi API'sinde güncel non-reasoning modelin
// alias'ı (OpenRouter'da deepseek/deepseek-v4-flash olarak test edilen model).
// Alias olduğu için DeepSeek adı değiştirirse ya da sabitlemek istersek
// DEEPSEEK_MODEL ile redeploy'suz çevrilebilir.
const DEEPSEEK_API_KEY = Deno.env.get("DEEPSEEK_API_KEY") ?? "";
const DEEPSEEK_URL = "https://api.deepseek.com/chat/completions";
const DEEPSEEK_MODEL = Deno.env.get("DEEPSEEK_MODEL") ?? "deepseek-chat";

export interface LlmMessage {
  role: string;
  // Görü blokları için dizi; düz sohbette string.
  content: string | Array<Record<string, unknown>>;
}

export interface LlmOptions {
  maxTokens: number;
  temperature: number;
  /** xAI'ye özel; DeepSeek yok sayar. Küçük bütçeli çağrılarda ASLA açma —
   *  reasoning tokenleri max_tokens'ı yiyip cevabı boşaltır. */
  reasoningEffort?: "none" | "low";
  /** xAI prompt-cache ipucu; DeepSeek'te karşılığı yok, yok sayılır. */
  convId?: string;
}

function hasVisionBlock(messages: LlmMessage[]): boolean {
  return messages.some((m) =>
    Array.isArray(m.content) && m.content.some((b) => b?.type === "image_url")
  );
}

function buildRequest(
  provider: "deepseek" | "xai",
  messages: LlmMessage[],
  opts: LlmOptions,
  stream: boolean,
): { url: string; init: RequestInit } {
  if (provider === "deepseek") {
    return {
      url: DEEPSEEK_URL,
      init: {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${DEEPSEEK_API_KEY}`,
        },
        body: JSON.stringify({
          model: DEEPSEEK_MODEL,
          messages,
          temperature: opts.temperature,
          max_tokens: opts.maxTokens,
          ...(stream ? { stream: true } : {}),
          // Cache için ayar yok: DeepSeek her isteğin ortak ÖNEKİNİ kendisi
          // cache'liyor ve isabeti giriş fiyatının ~1/5'inden faturalıyor.
          // Bunun karşılığı: her turda değişen hiçbir şey system prompt'un
          // içine girmemeli, yoksa önek her seferinde ıskalar.
        }),
      },
    };
  }
  return {
    url: XAI_URL,
    init: {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${XAI_API_KEY}`,
        ...(opts.convId ? { "x-grok-conv-id": opts.convId } : {}),
      },
      body: JSON.stringify({
        model: XAI_MODEL,
        messages,
        temperature: opts.temperature,
        max_tokens: opts.maxTokens,
        reasoning_effort: opts.reasoningEffort ?? "none",
        ...(stream ? { stream: true } : {}),
      }),
    },
  };
}

async function send(
  provider: "deepseek" | "xai",
  messages: LlmMessage[],
  opts: LlmOptions,
  stream: boolean,
): Promise<Response> {
  const { url, init } = buildRequest(provider, messages, opts, stream);
  const resp = await fetch(url, init);
  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`LLM ${provider} ${resp.status}: ${text.slice(0, 300)}`);
  }
  return resp;
}

function pickProvider(messages: LlmMessage[]): "deepseek" | "xai" {
  if (hasVisionBlock(messages)) return "xai";
  if (!DEEPSEEK_API_KEY) return "xai";
  return "deepseek";
}

async function withFallback(
  messages: LlmMessage[],
  opts: LlmOptions,
  stream: boolean,
): Promise<Response> {
  const provider = pickProvider(messages);
  if (provider === "xai") return await send("xai", messages, opts, stream);
  try {
    return await send("deepseek", messages, opts, stream);
  } catch (err) {
    // Hata vermek yerine düşmek: DeepSeek kesintisinde her kullanıcı hata
    // görürdü. O tur cevabı üslup olarak biraz kayacak (farklı model, prompt
    // DeepSeek'e göre ayarlı) ama uygulamanın komple durmasından iyi.
    // Loglanıyor ki sessiz ve KALICI bir fallback (ör. yanlış model alias'ı)
    // sadece "fatura neden yüksek" olarak değil, açıkça görünsün.
    if (!XAI_API_KEY) throw err;
    console.error("deepseek failed, falling back to xai:", String(err).slice(0, 300));
    return await send("xai", messages, opts, stream);
  }
}

/** Düz (stream'siz) tamamlama. Cevap metnini döndürür. */
export async function callLLM(messages: LlmMessage[], opts: LlmOptions): Promise<string> {
  const resp = await withFallback(messages, opts, false);
  const data = await resp.json();
  return data?.choices?.[0]?.message?.content ?? "";
}

/**
 * Stream'li tamamlama — ham upstream Response'u döndürür, gövdesi tüketilmeden.
 * Sesli arama yolu SSE'yi olduğu gibi ElevenLabs'e iletiyor; DeepSeek de xAI de
 * OpenAI biçiminde SSE ürettiği için iletilen sözleşme değişmiyor.
 */
export async function callLLMStream(messages: LlmMessage[], opts: LlmOptions): Promise<Response> {
  return await withFallback(messages, opts, true);
}
