//
//  CatalogService.swift
//  Ürün kataloğunu (ürün id -> token / tier) SUNUCUDAN okur.
//
//  Eskiden bu eşlemeler istemcide `PlummCatalog` olarak sabit yazılıydı.
//  Kaldırıldı: para karşılığı verilen bir miktarın iki yerde (istemci +
//  sunucu) tanımlı olması, biri güncellenip diğeri unutulduğunda kullanıcının
//  satın aldığından farklı miktar görmesi/alması demekti. Tek kaynak artık
//  supabase/functions/_shared/catalog.ts.
//
//  ÖNEMLİ: buradaki değerler yalnızca GÖSTERİM içindir (paywall'da "1.000
//  token" yazmak gibi). Kaç token verileceğine her zaman sunucu karar verir
//  (bkz. functions/purchase-tokens) — istemci hiçbir yerde miktar göndermez.
//

import Foundation
import Observation

@MainActor
@Observable
final class CatalogService {
    static let shared = CatalogService()
    private init() { load() }

    private(set) var tokenPacks: [String: Int] = [:]
    private(set) var subscriptionTokens: [String: Int] = [:]
    private(set) var productTier: [String: String] = [:]

    private struct Payload: Codable {
        let tokenPacks: [String: Int]
        let subscriptionTokens: [String: Int]
        let productTier: [String: String]
    }

    private static let cacheKey = "catalog.cached"

    /// Ürünün verdiği token — paket ya da abonelik, hangisiyse.
    /// Katalog henüz gelmediyse 0; çağıranlar bunu "bilinmiyor" olarak
    /// yorumlamalı (gösterimi gizle), "sıfır token" olarak değil.
    func tokens(for productId: String) -> Int {
        subscriptionTokens[productId] ?? tokenPacks[productId] ?? 0
    }

    func isTokenPack(_ productId: String) -> Bool {
        tokenPacks[productId] != nil
    }

    func tier(for productId: String) -> SubscriptionTier {
        switch productTier[productId] {
        case "max":      return .max
        case "pro_plus": return .proPlus
        case "pro":      return .pro
        default:         return .none
        }
    }

    /// Açılışta çağrılır. Ağ hatasında son başarılı katalog (UserDefaults)
    /// kullanılmaya devam eder — paywall'ın token sayısı boş kalmasın diye.
    func refresh() async {
        guard let accessToken = UserDefaultsManager.shared.accessToken,
              let url = URL(string: "\(Config.supabaseURL)/functions/v1/catalog")
        else { return }
        var req = URLRequest(url: url)
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            print("[Catalog] çekilemedi — önbellekteki katalog kullanılıyor (\(tokenPacks.count) paket)")
            return
        }
        apply(payload)
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
        print("[Catalog] yüklendi: \(payload.tokenPacks.count) paket, \(payload.subscriptionTokens.count) abonelik")
    }

    private func apply(_ p: Payload) {
        tokenPacks = p.tokenPacks
        subscriptionTokens = p.subscriptionTokens
        productTier = p.productTier
    }

    /// Soğuk açılışta ağ beklemeden ekranda doğru sayı olsun diye son
    /// başarılı katalog diskten okunur.
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let p = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }
        apply(p)
    }
}
