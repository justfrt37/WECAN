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
    /// DOĞRUDAN /auth/v1/signup DEĞİL — captcha korumasını (Attack Protection)
    /// proje genelinde KAPATMADAN sadece anonim girişi bypass eden
    /// `anon-signin` edge function'ı çağrılır (bkz. o dosyadaki açıklama:
    /// GoTrue captcha'yı yalnızca anon-key çağıranlara uygular, service_role
    /// ile yapılan aynı istek captcha'sız geçiyor — ampirik olarak
    /// doğrulandı 2026-08-26). Web'in kendi anon-key signup akışı etkilenmez.
    @discardableResult
    static func signInAnonymously() async -> Bool {
        guard let url = URL(string: "\(Config.supabaseURL)/functions/v1/anon-signin") else { return false }
        var r = URLRequest(url: url)
        r.timeoutInterval = 20
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
        r.timeoutInterval = 20
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
    ///
    /// KRİTİK: Eş zamanlı 401'ler (örn. ConversationsService aynı anda 3 istek
    /// atar) her biri ayrı ayrı recover() çağırırsa, biri refresh edip refresh
    /// token'ı ROTASYONA sokar; diğerleri artık geçersiz olan eski token'la
    /// refresh deneyip başarısız olur ve yeni bir ANONİM kullanıcı basardı —
    /// RLS'e bağlı tüm veriyi yetim bırakarak. Bu yüzden tüm kurtarma TEK bir
    /// seri (coalesce edilen) göreve toplanır: bir kurtarma zaten çalışıyorsa
    /// yenisi başlatılmaz, mevcut olan beklenir.
    @discardableResult
    static func recover() async -> Bool {
        await RecoveryCoordinator.shared.recover()
    }

    /// Kurtarmayı serileştiren aktör: aynı anda en fazla BİR kurtarma görevi.
    private actor RecoveryCoordinator {
        static let shared = RecoveryCoordinator()
        private var inFlight: Task<Bool, Never>?

        func recover() async -> Bool {
            // Zaten süren bir kurtarma varsa ona ortak ol (yeni refresh açma —
            // token-rotasyon yarışını böyle engelliyoruz).
            if let inFlight { return await inFlight.value }
            let task = Task { await SupabaseAuth.performRecovery() }
            inFlight = task
            let result = await task.value
            inFlight = nil
            return result
        }
    }

    /// Tek görevde çalışan gerçek kurtarma mantığı. Eş zamanlı çağıranlar bu
    /// göreve coalesce edildiği için burada token-rotasyon yarışı YOKTUR.
    private static func performRecovery() async -> Bool {
        for attempt in 1...3 {
            switch await attemptRefresh() {
            case .success:
                return true
            case .noToken, .rejected:
                // Yenilenecek geçerli oturum yok (token hiç yok) ya da sunucu
                // refresh token'ı kesin olarak reddetti (süresi doldu/iptal) —
                // ancak bu durumda gerçekten anonim kimliğe düşülür.
                return await signInAnonymously()
            case .networkError:
                if attempt < 3 {
                    let seconds = pow(2.0, Double(attempt - 1)) // 1s, 2s
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }
            }
        }
        // 3 denemede de yalnızca GEÇİCİ ağ hatası aldık ve refresh token hâlâ
        // elimizde: mevcut kimliği (ve RLS'e bağlı tüm veriyi) yeni bir anonim
        // kullanıcıyla EZMEKTENSE başarısız dön — çağıran daha sonra tekrar dener.
        return false
    }

    private enum RefreshOutcome { case success, rejected, networkError, noToken }

    /// refresh() ile aynı isteği kurar ama sonucu ayrıştırır: sunucunun token'ı
    /// kesin reddetmesi (.rejected, HTTP 400/401) ile geçici ağ/sunucu hatasını
    /// (.networkError) ayırır — böylece geçici hatada anonim kimliğe düşülmez.
    private static func attemptRefresh() async -> RefreshOutcome {
        guard let rt = UserDefaultsManager.shared.refreshToken,
              let url = URL(string: "\(Config.supabaseURL)/auth/v1/token?grant_type=refresh_token")
        else { return .noToken }
        var r = URLRequest(url: url)
        r.timeoutInterval = 20
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        r.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": rt])
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if (200..<300).contains(code) {
                guard let s = try? JSONDecoder().decode(Session.self, from: data),
                      let uid = s.user?.id, let token = s.access_token else {
                    // 2xx ama veri eksik/bozuk — geçici say, tekrar dene.
                    return .networkError
                }
                UserDefaultsManager.shared.userId = uid
                UserDefaultsManager.shared.accessToken = token
                UserDefaultsManager.shared.refreshToken = s.refresh_token
                return .success
            }
            // 400/401 = sunucu refresh token'ı reddetti (süresi dolmuş/iptal) →
            // gerçekten geçersiz. 5xx / diğerleri geçici sayılır.
            if code == 400 || code == 401 { return .rejected }
            return .networkError
        } catch {
            return .networkError
        }
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
            return true
        } catch {
            print("Supabase \(label) ağ hatası: \(error.localizedDescription)")
            return false
        }
    }
}
