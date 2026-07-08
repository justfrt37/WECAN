//
//  AuthService.swift
//  Supabase ANONİM giriş + retry (Bible'daki mantığın karşılığı).
//
//  1) Mevcut oturum varsa token'ı YENİLE (expired olabilir). Yenileme olmazsa
//     yeni anonim giriş.
//  2) Anonim giriş başarısızsa TEKRAR dene (max 3), ağ için backoff (1s,2s).
//  3) 3 deneme de başarısızsa loga "başarısız oldu" bas.
//
//  NOT: Supabase Dashboard > Authentication'da "Anonymous sign-ins" AÇIK olmalı.
//

import Foundation
import Observation

@MainActor
@Observable
final class AuthService {
    var isAuthenticated = false
    var isAuthenticating = false
    var failed = false

    private let maxAttempts = 3

    func bootstrap() async {
        guard !isAuthenticated, !isAuthenticating else { return }
        isAuthenticating = true
        failed = false

        let ok = await signInRetrySupabaseAuth()

        isAuthenticated = ok
        failed = !ok
        isAuthenticating = false
    }

    func retry() {
        Task { await bootstrap() }
    }

    private func signInRetrySupabaseAuth() async -> Bool {
        // Mevcut oturum varsa: token'ı yenile (expired olabilir). Bir kerelik
        // ağ hatası YÜZÜNDEN yeni anonim kimliğe düşülmesin — bu, kullanıcının
        // TÜM daha önce oluşturduğu karakterleri/sohbetleri (RLS: created_by =
        // auth.uid()) kalıcı olarak görünmez yapar, veri DB'de dursa bile.
        // O yüzden yeni kimliğe geçmeden önce refresh'i birkaç kez dene.
        if UserDefaultsManager.shared.userId != nil,
           UserDefaultsManager.shared.refreshToken != nil {
            print("Mevcut oturum bulundu — token yenileniyor")
            for attempt in 1...3 {
                if await SupabaseAuth.refresh() {
                    return true
                }
                if attempt < 3 {
                    let seconds = pow(2.0, Double(attempt - 1)) // 1s, 2s
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }
            }
            print("Token yenilenemedi (3 deneme) — yeni anonim giriş denenecek")
        }

        // Yeni anonim giriş + retry
        var attempt = 0
        while attempt < maxAttempts {
            attempt += 1
            print("Deneme: \(attempt)")
            if await SupabaseAuth.signInAnonymously() {
                return true
            }
            if attempt < maxAttempts {
                let seconds = pow(2.0, Double(attempt - 1)) // 1s, 2s
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }

        print("3 kere denendi, başarısız oldu")
        return false
    }
}
