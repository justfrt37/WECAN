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
}
