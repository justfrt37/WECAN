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

/// Üç ödemeli seviye — entitlement kimlikleri RevenueCat dashboard'daki
/// (henüz kurulmamış) "pro"/"pro_plus"/"max" entitlement'larıyla VE
/// `subscriptions.tier` check constraint'iyle (bkz. 005_token_system.sql)
/// AYNI kalmalı, biri değişirse diğeri de güncellenmeli.
enum SubscriptionTier: String {
    case none, pro, proPlus, max

    var weeklyTokens: Int {
        switch self {
        case .none: return 0
        case .pro: return 1000
        case .proPlus: return 2500
        case .max: return 6000
        }
    }

    var weeklyCharacterSlots: Int {
        switch self {
        case .none: return 0
        case .pro: return 1
        case .proPlus: return 3
        case .max: return 10
        }
    }
}

@MainActor
@Observable
final class PurchaseService {
    static let shared = PurchaseService()
    private init() {}

    /// RevenueCat dashboard → Project Settings → API Keys (public SDK key).
    private let apiKey = ""

    private(set) var isConfigured = false
    var tier: SubscriptionTier = .none
    /// Eski `isPro` çağrı yerleri (CreateCharacterView, LikesView, GalleryView,
    /// PaywallHostView) hiç değişmeden derlenmeye devam etsin diye korunuyor.
    var isPro: Bool { tier != .none }

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
        if info.entitlements["max"]?.isActive == true { tier = .max }
        else if info.entitlements["pro_plus"]?.isActive == true { tier = .proPlus }
        else if info.entitlements["pro"]?.isActive == true { tier = .pro }
        else { tier = .none }
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
