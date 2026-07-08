//
//  SupabaseAuth.swift
//  Supabase oturum işlemleri (anonim giriş + token yenileme).
//  Hem AuthService (açılış) hem ChatService (401'de) kullanır.
//

import Foundation

enum SupabaseAuth {
    private struct Session: Decodable {
        let access_token: String?
        let refresh_token: String?
        let user: User?
        struct User: Decodable { let id: String }
    }

    /// Yeni anonim oturum açar, token'ları saklar.
    @discardableResult
    static func signInAnonymously() async -> Bool {
        guard let url = URL(string: "\(Config.supabaseURL)/auth/v1/signup") else { return false }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        r.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        r.httpBody = "{}".data(using: .utf8)
        return await perform(r, label: "anonim giriş")
    }

    /// Saklı refresh_token ile yeni access_token alır.
    @discardableResult
    static func refresh() async -> Bool {
        guard let rt = UserDefaultsManager.shared.refreshToken,
              let url = URL(string: "\(Config.supabaseURL)/auth/v1/token?grant_type=refresh_token")
        else { return false }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        r.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": rt])
        return await perform(r, label: "token yenileme")
    }

    /// 401 sonrası kurtarma: önce refresh (birkaç kez — tek seferlik ağ
    /// hatası yüzünden anonim kimliğe düşülmesin, bkz. AuthService), olmazsa
    /// yeni anonim giriş.
    @discardableResult
    static func recover() async -> Bool {
        for attempt in 1...3 {
            if await refresh() { return true }
            if attempt < 3 {
                let seconds = pow(2.0, Double(attempt - 1)) // 1s, 2s
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
        return await signInAnonymously()
    }

    private static func perform(_ request: URLRequest, label: String) async -> Bool {
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                print("Supabase \(label) başarısız (HTTP \(code)): \(body)")
                return false
            }
            let s = try JSONDecoder().decode(Session.self, from: data)
            guard let uid = s.user?.id, let token = s.access_token else {
                print("Supabase \(label): veri eksik")
                return false
            }
            UserDefaultsManager.shared.userId = uid
            UserDefaultsManager.shared.accessToken = token
            UserDefaultsManager.shared.refreshToken = s.refresh_token
            print("Supabase \(label) OK — USERID: \(uid)")
            return true
        } catch {
            print("Supabase \(label) ağ hatası: \(error.localizedDescription)")
            return false
        }
    }
}
