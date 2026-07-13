//
//  Config.swift
//  Uygulama yapılandırması.
//
//  ÖNEMLİ: Grok (xAI) API key'i ASLA burada / istemcide tutulmaz.
//  Key Supabase Edge Function'da (sunucuda) saklanır. İstemci sadece
//  Supabase anon key ile Edge Function'ı çağırır.
//

import Foundation

enum Config {
    // Supabase proje ayarların (Supabase Dashboard > Project Settings > API Keys)
    static let supabaseURL = "https://ohpvhgwjmrfjclnumgnm.supabase.co"
    // ↓ Dashboard > Settings > API Keys > "anon / public" anahtarını buraya yapıştır
    static let supabaseAnonKey = "sb_publishable_AdvrSU0EhHDJyWsOtGGhZg_DHca3OaB"

    // Edge Function endpoint'i (LLM çağrısını sunucuda yapar, key'i gizler)
    static var chatFunctionURL: URL {
        URL(string: "\(supabaseURL)/functions/v1/chat")!
    }

    /// "Anı Ekle" / "Davranış Ekle" notlarını kaydeden Edge Function.
    static var addCharacterNoteFunctionURL: URL {
        URL(string: "\(supabaseURL)/functions/v1/add-character-note")!
    }

    /// Sesli mesaj (voice-note) sentezi — 28 ses × 7 dil, Google Cloud TTS.
    /// Var olan `tts` fonksiyonundan (eski konuşma-balonu-seslendirme,
    /// OpenAI tabanlı) BİLEREK AYRI — bkz. VoicePlayer.swift. Google TTS
    /// anahtarı bu Edge Function'ın Supabase secret'ı olarak sunucuda durur,
    /// istemcide hiç bulunmaz.
    static var voiceMessageTTSFunctionURL: URL {
        URL(string: "\(supabaseURL)/functions/v1/voice-message-tts")!
    }

    /// Kullanıcının sohbette yazdığı tarife göre xAI ile fotoğraf üretir.
    static var chatImageFunctionURL: URL {
        URL(string: "\(supabaseURL)/functions/v1/chat-image")!
    }

    /// Karakterin ilk günlük rutinini üretir (bkz. ChatViewModel.ensureScheduleGenerated).
    static var characterScheduleFunctionURL: URL {
        URL(string: "\(supabaseURL)/functions/v1/character-schedule")!
    }

    // MARK: DEV-only curated character creator (bkz. DevAccess, DevCharacterService)
    // TEMPORARY — DELETE alongside these Edge Functions once curated-character
    // creation is retired.

    static var devUploadImageFunctionURL: URL {
        URL(string: "\(supabaseURL)/functions/v1/dev-upload-image")!
    }

    static var devListVoicesFunctionURL: URL {
        URL(string: "\(supabaseURL)/functions/v1/dev-list-voices")!
    }

    static var devCreateCharacterFunctionURL: URL {
        URL(string: "\(supabaseURL)/functions/v1/dev-create-character")!
    }

    static var devUpdateCharacterFunctionURL: URL {
        URL(string: "\(supabaseURL)/functions/v1/dev-update-character")!
    }
}
