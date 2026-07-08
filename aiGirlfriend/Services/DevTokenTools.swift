//
//  DevTokenTools.swift
//  TEMPORARY — calls the `dev-token-tools` edge function for the Profile
//  tab's debug panel. DELETE alongside that function once real RevenueCat/
//  StoreKit purchases are wired up.
//

import Foundation

/// `TokenStore`/`PurchaseService` are both `@MainActor` — this whole enum
/// runs on the main actor too so it can call `setBalance`/set `tier`
/// directly, without every call site needing its own hop.
@MainActor
enum DevTokenTools {
    private struct Response: Decodable {
        let balance: Int?
        let tier: String?
    }

    @discardableResult
    private static func call(_ body: [String: Any]) async -> Response? {
        guard let accessToken = UserDefaultsManager.shared.accessToken,
              let url = URL(string: "\(Config.supabaseURL)/functions/v1/dev-token-tools")
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return try? JSONDecoder().decode(Response.self, from: data)
    }

    /// +1000 tokens, mimicking an outright token-pack purchase.
    static func addTokens(into tokenStore: TokenStore) async {
        guard let resp = await call(["action": "add_tokens"]), let balance = resp.balance else { return }
        tokenStore.setBalance(balance)
    }

    /// -1000 tokens (clamped at 0 server-side), mimicking heavy spend.
    static func removeTokens(from tokenStore: TokenStore) async {
        guard let resp = await call(["action": "remove_tokens"]), let balance = resp.balance else { return }
        tokenStore.setBalance(balance)
    }

    /// Sets (or clears) the caller's subscription tier — "off" deletes the
    /// row, anything else mimics a first-time subscribe: resets the weekly
    /// period AND drips that tier's weekly tokens (bkz. dev-token-tools).
    static func setTier(_ tier: SubscriptionTier, tokenStore: TokenStore) async {
        let wireTier: String
        switch tier {
        case .none: wireTier = "none"
        case .pro: wireTier = "pro"
        case .proPlus: wireTier = "pro_plus"
        case .max: wireTier = "max"
        }
        guard let resp = await call(["action": "set_tier", "tier": wireTier]) else { return }
        PurchaseService.shared.tier = tier
        if let balance = resp.balance { tokenStore.setBalance(balance) }
    }
}
