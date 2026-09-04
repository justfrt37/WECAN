//
//  SupabaseRequest.swift
//  Supabase isteklerinin ortak kurucusu. Her servis (REST okumaları + Edge
//  Function çağrıları) aynı `apikey` + `Authorization` başlık çiftini elle
//  kuruyordu; tek fark bearer'ın kaynağı ve timeout'tu — ikisi de parametre.
//
//  REST ile Edge Function ayrımı bilinçli: REST okumaları gövdesiz GET,
//  fonksiyon çağrıları JSON gövdeli POST (bkz. `post`).
//

import Foundation

enum SupabaseRequest {
    /// Oturum jetonu varsa o, yoksa anon key. Anon key ile RLS yalnızca herkese
    /// açık satırları döndürür — "giriş yapılmamışsa da çalışsın" isteyen
    /// çağrı yerleri bunu kullanır (bkz. CharacterService, ConversationsService).
    static var sessionBearer: String {
        UserDefaultsManager.shared.accessToken ?? Config.supabaseAnonKey
    }

    /// Supabase auth başlıklı taban istek. `timeout` nil ise URLRequest'in
    /// kendi varsayılanı (60 sn) korunur.
    static func authorized(url: URL, bearer: String, timeout: TimeInterval? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        if let timeout { request.timeoutInterval = timeout }
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// JSON gövdeli POST — Edge Function çağrılarının iskeleti. Gövde çağıran
    /// tarafından set edilir (kimi yerde JSONSerialization, kimi yerde Codable).
    static func post(url: URL, bearer: String, timeout: TimeInterval? = nil) -> URLRequest {
        var request = authorized(url: url, bearer: bearer, timeout: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
}
