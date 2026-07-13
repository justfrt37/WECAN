//
//  TokenStore.swift
//  Kullanıcının token bakiyesi — sunucu `token_balances` tablosunun tek
//  doğru kaynağı, istemci sadece okur/önbelleğe alır (bkz. GeneratedPhotoService
//  ile aynı RLS deseni: user_id = auth.uid()).
//

import Foundation
import Observation

@MainActor
@Observable
final class TokenStore {
    var balance: Int = 0
    /// Son `setBalance` çağrısındaki fark — TokenBadge bunu izleyip kısa bir
    /// "+1000"/"-25" animasyonu gösterir, sonra kendini `nil`'e sıfırlar
    /// (bkz. TokenBadge.spendAnimation). `refresh()` bunu TETİKLEMEZ — sadece
    /// gerçek harcama/kazanma anlarında (setBalance) dolar.
    var lastDelta: Int?
    /// Actual on-screen width of the TokenBadge overlay (bkz. TokenBadge,
    /// reported via GeometryReader) — the badge's width isn't fixed, it grows
    /// with the balance's digit count, so any screen reserving space for it
    /// (bkz. ChatView.header) reads this instead of guessing a fixed number.
    var badgeWidth: CGFloat = 80
    private let cacheKey = "tokens.cachedBalance"

    init() {
        balance = UserDefaults.standard.integer(forKey: cacheKey)
    }

    /// Splash'te ve her ödemeli eylemden sonra (mesaj/ses/foto gönderimi,
    /// satın alma, streak claim) çağrılır.
    func refresh() async {
        guard let accessToken = UserDefaultsManager.shared.accessToken,
              let url = URL(string: "\(Config.supabaseURL)/rest/v1/token_balances?select=balance")
        else { return }
        var request = URLRequest(url: url)
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return }
        struct Row: Decodable { let balance: Int }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data), let first = rows.first else { return }
        balance = first.balance
        UserDefaults.standard.set(first.balance, forKey: cacheKey)
    }

    /// Bir edge function cevabından gelen `tokenBalance` alanıyla anında
    /// günceller — bir sonraki `refresh()`'i beklemeden (bkz. ChatViewModel).
    func setBalance(_ value: Int) {
        let delta = value - balance
        balance = value
        UserDefaults.standard.set(value, forKey: cacheKey)
        if delta != 0 { lastDelta = delta }
    }
}
