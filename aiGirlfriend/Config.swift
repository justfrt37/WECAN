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
    /// OpenAI tabanlı) BİLEREK AYRI — bkz. VoicePlayer.swift.
    static var voiceMessageTTSFunctionURL: URL {
        URL(string: "\(supabaseURL)/functions/v1/voice-message-tts")!
    }

    // ⚠️ GEÇİCİ GÜVENLİK AÇIĞI — SADECE STOPGAP ⚠️
    // Supabase projesinde admin/owner yetkisi olmadığı için GOOGLE_TTS_API_KEY
    // Edge Function secret olarak eklenemedi (Dashboard > Edge Functions >
    // Secrets, rol bazlı yetki gerektiriyor). Bu key normalde İSTEMCİDE ASLA
    // durmamalı — burada duruyor olması app binary'sinden çıkarılabilir demek.
    // GCP Console'da bu key'in "Application restrictions" > "iOS apps" >
    // bundle ID (com.firat.aiGirlfriend) ile kısıtlandığı varsayılıyor — bu,
    // riski azaltır ama SIFIRLAMAZ (bundle ID sahteciliği mümkün).
    // Admin/owner erişimi olan biri secret'ı sunucuya taşıdığında: bu satırı
    // ve VoiceMap.swift'i sil, TTSService.synthesizeVoiceMessage'ı tekrar
    // voiceMessageTTSFunctionURL'i çağıracak şekilde geri al.
    static let googleTTSAPIKey = "AIzaSyAQMAOvGmL7Flth-Q65qrq0ZBT6gCHy6cE"
}
