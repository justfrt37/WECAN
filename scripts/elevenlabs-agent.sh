#!/usr/bin/env bash
# Sesli aramanın ElevenLabs Agent ayarlarını okumak/değiştirmek için.
#
# NEDEN BU SCRIPT VAR: aramanın davranışını belirleyen ayarların bir kısmı
# repoda DEĞİL, ElevenLabs tarafındaki agent kaydında duruyor — TTS modeli
# (eleven_v3_conversational mı, flash mı), ASR/dil ayarı, hangi override'lara
# izin verildiği ve sessizlikte yeniden konuşma süresi (turn_timeout). Kod
# yorumlarında "agent v3_conversational'a geçti" yazıyor ama bunu doğrulamanın
# tek yolu API'den okumak. Panelden bakmak yerine buradan bakılırsa ne
# okunduğu ve ne yazıldığı sürüm kontrolünde kalır.
#
# Kullanım:
#   ELEVEN_LABS=<api-key> scripts/elevenlabs-agent.sh get          # özet
#   ELEVEN_LABS=<api-key> scripts/elevenlabs-agent.sh raw          # tam JSON
#   ELEVEN_LABS=<api-key> scripts/elevenlabs-agent.sh set-turn-timeout 10
#   ELEVEN_LABS=<api-key> scripts/elevenlabs-agent.sh set-model eleven_v3_conversational
#
# ELEVENLABS_AGENT_ID verilmezse voice-call-start'taki değer kullanılır.

set -euo pipefail

AGENT_ID="${ELEVENLABS_AGENT_ID:-agent_5701kyp1mydkfqnsfn9zw0c2jbqn}"
API_KEY="${ELEVEN_LABS:-}"
BASE="https://api.elevenlabs.io/v1/convai/agents/${AGENT_ID}"

if [[ -z "$API_KEY" ]]; then
  echo "ELEVEN_LABS ortam değişkeni gerekli (Supabase'deki ses anahtarı)." >&2
  exit 1
fi

cmd="${1:-get}"

case "$cmd" in
  raw)
    curl -sS -H "xi-api-key: ${API_KEY}" "$BASE" | python3 -m json.tool
    ;;

  get)
    # Aramada gerçekten etkili olan alanları çekip düz bir özet basıyor.
    curl -sS -H "xi-api-key: ${API_KEY}" "$BASE" | python3 - <<'PY'
import json, sys
a = json.load(sys.stdin)
cc = a.get("conversation_config", {})
tts = cc.get("tts", {})
agent = cc.get("agent", {})
asr = cc.get("asr", {})
turn = cc.get("turn", {})
ov = (a.get("platform_settings", {}) or {}).get("overrides", {})

print(f"agent            : {a.get('name')} ({a.get('agent_id')})")
print()
print("— TTS —")
print(f"  model_id       : {tts.get('model_id')}")
print(f"  voice_id       : {tts.get('voice_id')}")
print(f"  stability      : {tts.get('stability')}   speed: {tts.get('speed')}")
print()
print("— Dil —")
print(f"  default        : {agent.get('language')}")
print(f"  additional     : {cc.get('language_presets', {}).keys() and list(cc.get('language_presets', {}).keys())}")
print(f"  asr language   : {asr.get('language') or asr.get('user_input_audio_format') and '(asr bloğu aşağıda)'}")
print(f"  asr quality    : {asr.get('quality')}  provider: {asr.get('provider')}")
print()
print("— Sessizlik / tur —")
print(f"  turn_timeout   : {turn.get('turn_timeout')}")
print(f"  silence_end_call_timeout: {turn.get('silence_end_call_timeout')}")
print(f"  mode           : {turn.get('mode')}")
print()
print("— İzin verilen override'lar (istemci bunları gönderebilir) —")
print(json.dumps(ov, indent=2, ensure_ascii=False))
print()
print("— LLM —")
print(f"  custom llm url : {(agent.get('prompt') or {}).get('custom_llm', {}).get('url')}")
print(f"  first_message  : {agent.get('first_message')!r}")
PY
    ;;

  set-model)
    # TTS modeli. Aramada istediğimiz: eleven_v3_conversational (ses etiketleri
    # [laughs]/[whispers] SADECE bu modelde performansa dönüşüyor; flash ve
    # multilingual v2.5 onları KELİME olarak okuyor).
    #
    # DİKKAT: ElevenLabs dokümanı "additional languages switch the agent to use
    # the v2.5 Multilingual model" diyor. Yani agent'a ek dil (tr) tanımlıysa
    # Türkçe aramalar bu model_id'yi GÖRMEZDEN gelip v2.5'e düşebilir. Bu
    # komuttan sonra `get` ile hem model_id'yi hem language_presets'i kontrol
    # et; Türkçe için ayrıca preset içinde model gerekiyorsa oradan set edilir.
    model="${2:-eleven_v3_conversational}"
    curl -sS -X PATCH "$BASE" \
      -H "xi-api-key: ${API_KEY}" \
      -H "Content-Type: application/json" \
      -d "{\"conversation_config\":{\"tts\":{\"model_id\":\"${model}\"}}}" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print('model_id =', d.get('conversation_config',{}).get('tts',{}).get('model_id'))"
    ;;

  set-turn-timeout)
    secs="${2:-10}"
    # Sessizlikte karakterin yeniden konuşmaya başlaması için beklenen süre.
    # voice-call-llm-webhook'taki re-engage promptu "about ten seconds" diyor —
    # buradaki değeri değiştirirsen o metni de güncelle, yoksa karakter iki
    # saniyelik sessizlikte "çok sessizsin" demeye başlar.
    curl -sS -X PATCH "$BASE" \
      -H "xi-api-key: ${API_KEY}" \
      -H "Content-Type: application/json" \
      -d "{\"conversation_config\":{\"turn\":{\"turn_timeout\":${secs}}}}" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print('turn_timeout =', d.get('conversation_config',{}).get('turn',{}).get('turn_timeout'))"
    ;;

  *)
    echo "bilinmeyen komut: $cmd (get | raw | set-model <model_id> | set-turn-timeout <saniye>)" >&2
    exit 1
    ;;
esac
