//
//  VoiceMap.swift
//  28 sesli-mesaj kombinasyonu (7 personality_role × 4 vibe) → Google Chirp3-HD
//  ses ismi. Swift'e taşınmış kopya: `supabase/functions/voice-message-tts/voiceMap.ts`
//  ile AYNI 28 girdi. Bu dosya SADECE geçici client-side stopgap için var —
//  Supabase proje admin erişimi olan biri GOOGLE_TTS_API_KEY'i Edge Function
//  secret olarak eklediğinde bu dosya ve Config.googleTTSAPIKey silinip
//  TTSService.synthesizeVoiceMessage tekrar voice-message-tts fonksiyonunu
//  çağıracak şekilde geri alınmalı (bkz. VoicePlayer.swift'teki not).
//

import Foundation

enum VoiceMap {
    private static let map: [String: String] = [
        // flirty
        "flirty_Sweet": "Aoede",
        "flirty_Mysterious": "Kore",
        "flirty_Energetic": "Puck",
        "flirty_Elegant": "Zephyr",
        // distant
        "distant_Sweet": "Leda",
        "distant_Mysterious": "Charon",
        "distant_Energetic": "Orus",
        "distant_Elegant": "Umbriel",
        // shy
        "shy_Sweet": "Despina",
        "shy_Mysterious": "Enceladus",
        "shy_Energetic": "Erinome",
        "shy_Elegant": "Gacrux",
        // playful
        "playful_Sweet": "Autonoe",
        "playful_Mysterious": "Callirrhoe",
        "playful_Energetic": "Achird",
        "playful_Elegant": "Algenib",
        // devoted
        "devoted_Sweet": "Algieba",
        "devoted_Mysterious": "Alnilam",
        "devoted_Energetic": "Laomedeia",
        "devoted_Elegant": "Pulcherrima",
        // crazy
        "crazy_Sweet": "Rasalgethi",
        "crazy_Mysterious": "Sadachbia",
        "crazy_Energetic": "Sadaltager",
        "crazy_Elegant": "Fenrir",
        // ex
        "ex_Sweet": "Schedar",
        "ex_Mysterious": "Sulafat",
        "ex_Energetic": "Iapetus",
        "ex_Elegant": "Vindemiatrix",
    ]

    private static let defaultVoice = "Aoede"

    private static let localeForLang: [String: String] = [
        "tr": "tr-TR", "en": "en-US", "de": "de-DE", "fr": "fr-FR",
        "es": "es-ES", "pt": "pt-PT", "it": "it-IT",
    ]

    static func voiceName(role: String, vibe: String, lang: String) -> String {
        let chirpName = map["\(role)_\(vibe)"] ?? defaultVoice
        let locale = localeForLang[lang] ?? "en-US"
        return "\(locale)-Chirp3-HD-\(chirpName)"
    }

    static func localeCode(forLang lang: String) -> String {
        localeForLang[lang] ?? "en-US"
    }
}
