//
//  PurchaseService.swift
//  RevenueCat iskeleti — PRO abonelik sistemi henüz kurulmadı, ama tüm PRO
//  butonları/rozetleri bu servise bağlı. RevenueCat SDK Xcode'dan eklenip
//  `apiKey` dolduruldğunda tüm sistem otomatik aktifleşir, başka kod değişikliği
//  GEREKMEZ.
//
//  KURULUM (yapılmadı, elle yapılmalı):
//   1) Xcode → File → Add Package Dependencies →
//      https://github.com/RevenueCat/purchases-ios.git
//      "RevenueCat" ve "RevenueCatUI" ürünlerini hedefe ekle.
//   2) `apiKey` alanına RevenueCat dashboard'daki public SDK key'i yaz.
//   3) RevenueCat dashboard'da "pro" adında bir entitlement oluştur (veya
//      `proEntitlementId` sabitini kendi entitlement adınla değiştir).
//
//  Paket eklenene kadar `canImport` guard'ları sayesinde proje NORMAL DERLENIR;
//  `isPro` her zaman false döner, `presentPaywall()` sadece log basar.
//

import Foundation
import Observation
#if canImport(RevenueCat)
import RevenueCat
#endif

@MainActor
@Observable
final class PurchaseService {
    static let shared = PurchaseService()
    private init() {}

    /// RevenueCat dashboard → Project Settings → API Keys (public SDK key).
    private let apiKey = ""
    private let proEntitlementId = "pro"

    private(set) var isConfigured = false
    var isPro: Bool = false

    func configure() {
        #if canImport(RevenueCat)
        guard !apiKey.isEmpty, !isConfigured else { return }
        Purchases.logLevel = .warn
        Purchases.configure(withAPIKey: apiKey)
        isConfigured = true
        Task { await refreshEntitlement() }
        #else
        print("[PurchaseService] RevenueCat SDK eklenmedi — PRO sistemi pasif (bkz. dosya başı kurulum notu).")
        #endif
    }

    func refreshEntitlement() async {
        #if canImport(RevenueCat)
        guard isConfigured, let info = try? await Purchases.shared.customerInfo() else { return }
        isPro = info.entitlements[proEntitlementId]?.isActive == true
        #endif
    }

    /// Paywall gösterilmesi gereken her yerden çağrılır (PRO banner, galeri CTA, rozet vb).
    /// RevenueCatUI eklenene kadar çağıran view'lar basit bir "yakında" sheet'i gösterir
    /// (bkz. `PaywallHostView`), gerçek paywall UI'ı otomatik devreye girer.
    func presentPaywall() {
        guard isConfigured else {
            print("[PurchaseService] Paywall istendi ama RevenueCat henüz yapılandırılmadı.")
            return
        }
    }
}
