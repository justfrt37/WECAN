//
//  StreakService.swift
//  `claim-streak` edge function'ını çağırır — asıl hak verme mantığı ve
//  UTC-tabanlı kötüye kullanım koruması TAMAMEN sunucuda (bkz. design doc).
//

import Foundation

struct StreakClaimResult: Decodable {
    let granted: Bool
    let amount: Int?
    let newStreak: Int?
    let balance: Int?
}

enum StreakService {
    static func claim() async -> StreakClaimResult? {
        guard let accessToken = UserDefaultsManager.shared.accessToken,
              let url = URL(string: "\(Config.supabaseURL)/functions/v1/claim-streak")
        else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        // Cihazın kendi yerel takvim günü — SADECE kozmetik gösterim için
        // (bkz. StreakPopupView). Gerçek hak verme kararı sunucunun UTC
        // saatine göre çalışır (bkz. claim-streak, MIN_HOURS_BETWEEN_CLAIMS).
        let localDateFormatter = DateFormatter()
        localDateFormatter.dateFormat = "yyyy-MM-dd"
        localDateFormatter.timeZone = .current
        let localDate = localDateFormatter.string(from: Date())
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["localDate": localDate])

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return try? JSONDecoder().decode(StreakClaimResult.self, from: data)
    }
}
