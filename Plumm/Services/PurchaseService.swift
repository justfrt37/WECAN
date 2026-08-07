//
//  PurchaseService.swift
//  RevenueCat abonelik sistemi. Paywall'lar (OnboardingPaywallView +
//  SubscriptionPaywallView) buradaki `packages` (ucuzdan pahalıya sıralı) ile
//  beslenir; satın alma/geri yükleme buradan yapılır.
//
//  Kurulum:
//   • SPM paketi (github.com/RevenueCat/purchases-ios) Xcode projesine eklendi
//     (RevenueCat + RevenueCatUI + ReceiptParser hedefe bağlı).
//   • `apiKey` = Apple public SDK key (appl_...).
//   • Entitlement id'leri dashboard'da "pro" / "pro_plus" / "max" olmalı
//     (bkz. refreshEntitlement + subscriptions.tier constraint 005_token_system.sql).
//
//  Paket resolve olmadan da derlensin diye `#if canImport(RevenueCat)` guard'ları
//  korundu; paket yokken `packages` boş, satın alma no-op döner.
//

import Foundation
import Observation
import StoreKit
#if canImport(RevenueCat)
import RevenueCat
#endif

/// UI'ın RevenueCat'i import etmeden kullanabileceği hafif paket modeli.
/// `priceValue` yalnızca ucuzdan pahalıya sıralamak için tutulur.
struct PaywallPackage: Identifiable {
    let id: String            // RevenueCat package identifier
    let productId: String     // StoreKit ürün id'si (ör. "weekly_pro_max")
    let title: String         // ürün başlığı (ör. "Weekly", "Annual")
    let periodName: String    // temiz İngilizce periyot adı: "Weekly"/"Monthly"/"Yearly"
    let localizedPrice: String // yerelleştirilmiş fiyat (ör. "₺1.499,99")
    let priceValue: Decimal    // sıralama için ham fiyat
    let periodLabel: String?   // "/wk", "/mo", "/yr" vb.
    let weeklyEquivalent: String? // varsa "$0.96 / week"
    let perWeekValue: Decimal? // haftalık eşdeğer ham fiyat (tasarruf % hesabı için)
    let tokenAmount: Int      // bu ürünün verdiği token (abonelik dönem grant'ı / paket adedi)
    #if canImport(RevenueCat)
    let rcPackage: Package
    #endif
}

/// Ürün kataloğu — product id → tier ve token miktarı (dashboard fiyatları
/// dinamik; bu iki alan sabit iş kuralı). Server (`sync-subscription`) ve
/// dev-token-tools ile AYNI kalmalı.
enum PlummCatalog {
    /// Abonelik ürününün dönem başına verdiği token.
    static let subscriptionTokens: [String: Int] = [
        "weekly_pro_normal": 250, "monthly_pro_default": 1000, "yearly_pro_normal": 12000,
        "weekly_pro_plus": 500,   "monthly_pro_plus": 2000,    "yearly_pro_plus": 25000,
        "weekly_pro_max": 750,    "monthly_pro_max": 3000,     "yearly_pro_max": 35000,
    ]
    /// Tek seferlik token paketleri.
    static let tokenPackTokens: [String: Int] = [
        "token_100": 100, "token_250": 250, "token_500": 500,
        "token_1000": 1000, "token_2000": 2000, "token_5000": 5000,
    ]
    static let productTier: [String: SubscriptionTier] = [
        "weekly_pro_normal": .pro,     "monthly_pro_default": .pro,  "yearly_pro_normal": .pro,
        "weekly_pro_plus": .proPlus,   "monthly_pro_plus": .proPlus, "yearly_pro_plus": .proPlus,
        "weekly_pro_max": .max,        "monthly_pro_max": .max,      "yearly_pro_max": .max,
    ]
    static func tokens(for productId: String) -> Int {
        subscriptionTokens[productId] ?? tokenPackTokens[productId] ?? 0
    }
    static func tier(for productId: String) -> SubscriptionTier {
        productTier[productId] ?? .none
    }
    static func isTokenPack(_ productId: String) -> Bool { tokenPackTokens[productId] != nil }
}

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

    /// Haftalık karakter yaratma hakkı. `nil` = SINIRSIZ (Pro Max).
    /// KAYNAK-DOĞRU değer sunucuda (supabase/functions/_shared/entitlements.ts);
    /// burası paywall metni + boşuna istek atmamak için ayna.
    var weeklyCharacterSlots: Int? {
        switch self {
        case .none: return 0
        case .pro: return 1
        case .proPlus: return 5
        case .max: return nil      // sınırsız
        }
    }

    /// Ses özellikleri (sesli mesaj + sesli arama) — Pro'da YOK, Pro+ ve Max'te var.
    /// Sunucu da aynı kuralı uygular (voice-message-tts / voice-call-start 403 döner).
    var canUseVoice: Bool {
        switch self {
        case .none, .pro: return false
        case .proPlus, .max: return true
        }
    }

    var displayName: String {
        switch self {
        case .none: return "Free"
        case .pro: return "Pro"
        case .proPlus: return "Pro+"
        case .max: return "Max"
        }
    }
}

@MainActor
@Observable
final class PurchaseService {
    static let shared = PurchaseService()
    private init() {}

    /// RevenueCat dashboard → Project Settings → API Keys → Apple (public SDK key).
    private let apiKey = "appl_YzftwpUEULzIDwEgSAPOtuSddHa"

    private(set) var isConfigured = false
    // Non-PRO test için .none (bkz. kullanıcı talebi). PRO test etmek istersen
    // DEBUG'ta tekrar .pro yapabilirsin.
    var tier: SubscriptionTier = .none
    /// Eski `isPro` çağrı yerleri (CreateCharacterView, LikesView, GalleryView,
    /// PaywallHostView) hiç değişmeden derlenmeye devam etsin diye korunuyor.
    var isPro: Bool { tier != .none }
    /// Ses (sesli mesaj + sesli arama) hakkı — Pro'da YOK, Pro+/Max'te var.
    /// Sunucu da aynı kuralı uygular; bu yalnızca boşuna istek atmamak için.
    var canUseVoice: Bool { tier.canUseVoice }

    // Tier başına abonelik paketleri (weekly→monthly→yearly sıralı) ve token
    // paketleri. Ana paywall tier seçicisi bunları gösterir.
    private(set) var proPackages: [PaywallPackage] = []
    private(set) var proPlusPackages: [PaywallPackage] = []
    private(set) var maxPackages: [PaywallPackage] = []
    private(set) var tokenPackages: [PaywallPackage] = []   // ucuzdan pahalıya
    private(set) var isLoadingOfferings = false

    /// Onboarding paywall'ı için geriye-uyumlu: Pro (default offering) paketleri.
    var packages: [PaywallPackage] { proPackages }

    func packages(for tier: SubscriptionTier) -> [PaywallPackage] {
        switch tier {
        case .pro:     return proPackages
        case .proPlus: return proPlusPackages
        case .max:     return maxPackages
        case .none:    return []
        }
    }

    func configure() {
        #if canImport(RevenueCat)
        guard !apiKey.isEmpty, !isConfigured else { return }
        Purchases.logLevel = .debug
        Purchases.configure(withAPIKey: apiKey)
        isConfigured = true
        Task {
            // RC'nin appUserID'sini Supabase uid'ine EŞİTLE — böylece
            // revenuecat-webhook'un aldığı `app_user_id` doğrudan bizim
            // `subscriptions.user_id`'imiz olur, ayrı bir eşleme tablosu
            // gerekmez. logIn olmadan RC kendi anonim ID'sini kullanırdı
            // (bkz. kullanıcı talebi — webhook ile sunucu taraflı doğrulama).
            if let uid = UserDefaultsManager.shared.userId {
                _ = try? await Purchases.shared.logIn(uid)
            }
            await refreshEntitlement()
            await loadOfferings()
        }
        #else
        print("[PurchaseService] RevenueCat SDK eklenmedi — PRO sistemi pasif (bkz. dosya başı kurulum notu).")
        #endif
    }

    /// Tüm offering'leri (default=Pro, plus=Pro+, max=Pro Max, tokens) çeker.
    func loadOfferings() async {
        #if canImport(RevenueCat)
        guard isConfigured else { return }
        isLoadingOfferings = true
        defer { isLoadingOfferings = false }
        do {
            let offerings = try await Purchases.shared.offerings()
            proPackages     = Self.mapPackages(offerings.all["default"])
            proPlusPackages = Self.mapPackages(offerings.all["plus"])
            maxPackages     = Self.mapPackages(offerings.all["max"])
            tokenPackages   = Self.mapPackages(offerings.all["tokens"])
            print("[PW] offerings yüklendi pro=\(proPackages.count) plus=\(proPlusPackages.count) max=\(maxPackages.count) tokens=\(tokenPackages.count)")
        } catch {
            print("[PW] offerings HATA: \(error)")
        }
        #endif
    }

    #if canImport(RevenueCat)
    /// Bir offering'in paketlerini PaywallPackage'a çevirir, fiyata göre
    /// (ucuzdan pahalıya) sıralar. Abonelikte weekly<monthly<yearly, tokende küçük<büyük.
    private static func mapPackages(_ offering: Offering?) -> [PaywallPackage] {
        guard let offering else { return [] }
        return offering.availablePackages.map { pkg in
            let p = pkg.storeProduct
            return PaywallPackage(
                id: pkg.identifier,
                productId: p.productIdentifier,
                title: p.localizedTitle,
                periodName: Self.periodName(for: p),
                localizedPrice: p.localizedPriceString,
                priceValue: p.price,
                periodLabel: Self.periodLabel(for: p),
                weeklyEquivalent: Self.weeklyEquivalent(for: p),
                perWeekValue: Self.perWeekValue(for: p),
                tokenAmount: PlummCatalog.tokens(for: p.productIdentifier),
                rcPackage: pkg
            )
        }
        .sorted { $0.priceValue < $1.priceValue }
    }
    #endif

    /// Seçili paketi satın alır. Başarılıysa entitlement'i tazeler; iptal/hata → false.
    @discardableResult
    func purchase(_ package: PaywallPackage) async -> Bool {
        #if canImport(RevenueCat)
        guard isConfigured else { return false }
        // configure()'daki logIn, uid henüz yazılmamışken (uygulama açılış
        // yarışı) sessizce atlanmış olabilir — burada, kullanıcı gerçekten bir
        // satın alma yaptığı an, uid KESİN mevcut, o yüzden tekrar deneriz.
        // logIn idempotent, aynı id'yle tekrar çağırmak zararsız.
        if let uid = UserDefaultsManager.shared.userId, Purchases.shared.appUserID != uid {
            _ = try? await Purchases.shared.logIn(uid)
        }
        do {
            let result = try await Purchases.shared.purchase(package: package.rcPackage)
            guard !result.userCancelled else { return false }

            if PlummCatalog.isTokenPack(package.productId) {
                // Token PAKETİ (consumable): entitlement/subscription üretmez.
                #if DEBUG
                await debugGrantTokens(package.tokenAmount)
                #endif
                // (Production: ileride RC non_subscriptions doğrulamalı bir sunucu
                //  akışı gerekli — şimdilik DEBUG grant.)
            } else {
                // Abonelik: sunucu token ekonomisine köprü.
                await refreshEntitlement()
                await syncWithServer()
                #if DEBUG
                // Simülatör: RC yerel StoreKit Testing satın almalarını sunucuya
                // KAYDETMEZ → syncWithServer boş döner. Aktif aboneliği StoreKit'ten
                // bulup ürüne özel token'ı dev-token-tools ile ver (dönem-idempotent).
                if tier == .none { await debugGrantFromStoreKit() }
                #endif
            }
            // Satın alma TAMAMLANDIYSA (iptal/hata değil) true — paywall kapanmalı.
            return true
        } catch {
            print("[PurchaseService] purchase hatası: \(error.localizedDescription)")
            return false
        }
        #else
        return false
        #endif
    }

    /// "Satın alımları geri yükle".
    @discardableResult
    func restore() async -> Bool {
        #if canImport(RevenueCat)
        guard isConfigured else { return false }
        if let uid = UserDefaultsManager.shared.userId, Purchases.shared.appUserID != uid {
            _ = try? await Purchases.shared.logIn(uid)
        }
        _ = try? await Purchases.shared.restorePurchases()
        await refreshEntitlement()
        await syncWithServer()
        #if DEBUG
        // Simülatörde restore: RC sunucusu yerel satın almayı görmediğinden
        // syncWithServer boş döner. StoreKit'teki aktif aboneliği bulup grant et
        // (idempotent — aynı dönemde token EKLEMEZ).
        if tier == .none { await debugGrantFromStoreKit() }
        #endif
        #endif
        return isPro
    }

    /// Sunucu tarafı token ekonomisine köprü. `sync-subscription` edge
    /// function'ını çağırır: RC entitlement'ı secret key ile SUNUCUDA doğrulanır,
    /// `subscriptions` satırı upsert edilir ve tier'ın haftalık token'ları verilir
    /// (aynı dönemde tekrar çağrılınca yeniden vermez). `tier`'ı sunucu yanıtına
    /// göre günceller, yeni token bakiyesini döndürür (TokenStore.refresh için).
    @discardableResult
    func syncWithServer() async -> Int? {
        #if canImport(RevenueCat)
        guard isConfigured,
              let accessToken = UserDefaultsManager.shared.accessToken,
              let url = URL(string: "\(Config.supabaseURL)/functions/v1/sync-subscription")
        else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let appUserId = Purchases.shared.appUserID
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["appUserId": appUserId])
        struct SyncResponse: Decodable { let tier: String?; let balance: Int? }
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            print("[PW-DIAG] sync ağ hatası")
            return nil
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        print("[PW-DIAG] sync appUserId=\(appUserId) status=\(status) body=\(String(data: data, encoding: .utf8) ?? "")")
        guard (200..<300).contains(status),
              let decoded = try? JSONDecoder().decode(SyncResponse.self, from: data)
        else { return nil }
        // "Tier yok" yanıtı tier'ı DÜŞÜRMEZ — sync-subscription sadece token
        // ekonomisi köprüsü, gerçek doğruluk kaynağı değil. Az önce aynı
        // fonksiyonda çağrılan refreshEntitlement() zaten RC'den (Apple'ın
        // kendisinden) doğrudan doğruladı; sandbox'ta RC→sunucu doğrulaması
        // gecikebilir/webhook henüz işlenmemiş olabilir ve bu satır olmadan
        // az önce doğrulanmış PRO durumunu yanlışlıkla .none'a çekip paywall'ı
        // tekrar açtırıyordu (bkz. kullanıcı talebi — satın aldıktan sonra
        // paywall'ın farklı yerlerde tekrar çıkması). `refreshServerTier()`
        // zaten aynı ilkeyi uyguluyor ("satır yoksa dokunma").
        switch decoded.tier {
        case "max":      tier = .max
        case "pro_plus": tier = .proPlus
        case "pro":      tier = .pro
        default:         break
        }
        return decoded.balance
        #else
        return nil
        #endif
    }

    #if DEBUG
    /// Satın alınan ürün id'sinden tier çıkarır (katalogdan).
    private func tier(forProductId productId: String) -> SubscriptionTier {
        PlummCatalog.tier(for: productId)
    }

    /// SADECE DEBUG: bir token PAKETİ (consumable) satın alınınca adedini sunucuda
    /// verir. Consumable entitlement/subscription üretmediği için normal sync yolu
    /// bunu yakalamaz; dev-token-tools ile doğrudan grant edilir.
    private func debugGrantTokens(_ amount: Int) async {
        guard amount > 0,
              let accessToken = UserDefaultsManager.shared.accessToken,
              let url = URL(string: "\(Config.supabaseURL)/functions/v1/dev-token-tools")
        else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["action": "grant", "amount": amount])
        _ = try? await URLSession.shared.data(for: req)
        print("[PW] DEBUG token paketi grant: +\(amount)")
    }

    /// StoreKit-2'den ŞU AN aktif (doğrulanmış, süresi geçmemiş) abonelik ürününü
    /// ve dönem başlangıcını (idempotency anahtarı) bulur.
    private func activeStoreKitSubscription() async -> (productId: String, periodStart: String)? {
        var found: (String, Date)?
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let tx) = result, tx.revocationDate == nil else { continue }
            if let exp = tx.expirationDate, exp < Date() { continue }
            guard tier(forProductId: tx.productID) != .none else { continue }
            found = (tx.productID, tx.purchaseDate)   // en son (renewal) işlem
        }
        guard let f = found else { return nil }
        return (f.0, ISO8601DateFormatter().string(from: f.1))
    }

    /// SADECE DEBUG: aktif StoreKit aboneliğinin tier'ını sunucuda verir.
    private func debugGrantFromStoreKit() async {
        guard let sub = await activeStoreKitSubscription() else {
            print("[PW-DIAG] DEBUG grant: aktif StoreKit aboneliği bulunamadı")
            return
        }
        await debugGrantTier(forProductId: sub.productId, periodStart: sub.periodStart)
    }

    /// SADECE DEBUG: ürünün tier'ını `dev-token-tools` (set_tier) ile sunucuda verir —
    /// subscription satırı + ürüne özel token. `periodStart` ile DÖNEM BAŞINA
    /// idempotenttir (aynı dönemde tekrar çağrılınca token EKLEMEZ). RC sunucusu
    /// yerel StoreKit Testing satın almalarını görmediği için simülatörde gereklidir.
    private func debugGrantTier(forProductId productId: String, periodStart: String) async {
        let mapped = tier(forProductId: productId)
        guard mapped != .none else { return }
        let wire = mapped.rawValue == "proPlus" ? "pro_plus" : mapped.rawValue
        let tokens = Self.productTokens(for: productId)
        guard let accessToken = UserDefaultsManager.shared.accessToken,
              let url = URL(string: "\(Config.supabaseURL)/functions/v1/dev-token-tools")
        else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "action": "set_tier", "tier": wire, "tokens": tokens, "periodStart": periodStart,
        ])
        _ = try? await URLSession.shared.data(for: req)
        tier = mapped
        print("[PW-DIAG] DEBUG grant tier=\(wire) tokens=\(tokens) period=\(periodStart)")
    }
    #endif

    /// Ürüne göre verilecek token miktarı (katalogdan).
    static func productTokens(for productId: String) -> Int {
        PlummCatalog.tokens(for: productId)
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

    /// Sunucudaki `subscriptions` tablosundan tier'ı okur. Token ekonomisinin
    /// gerçek kaynağı sunucu olduğu için (özellikle simülatörde RC entitlement'ı
    /// boşken), açılışta `isPro`/tier'ın DOĞRU görünmesini bu sağlar — kullanıcı
    /// restore'a basmadan pro olduğunu bilir. Sunucuda satır yoksa tier düşürülmez
    /// (RC entitlement'ı geçerliyse korunur).
    func refreshServerTier() async {
        guard let accessToken = UserDefaultsManager.shared.accessToken,
              let url = URL(string: "\(Config.supabaseURL)/rest/v1/subscriptions?select=tier")
        else { return }
        var req = URLRequest(url: url)
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return }
        struct Row: Decodable { let tier: String }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return }
        guard let t = rows.first?.tier else { return }   // satır yoksa dokunma
        switch t {
        case "max":      tier = .max
        case "pro_plus": tier = .proPlus
        case "pro":      tier = .pro
        default:         break
        }
    }

    /// Paywall gösterilmesi gereken her yerden çağrılır (PRO banner, galeri CTA, rozet vb).
    func presentPaywall() {
        guard isConfigured else {
            print("[PurchaseService] Paywall istendi ama RevenueCat henüz yapılandırılmadı.")
            return
        }
    }

    #if canImport(RevenueCat)
    /// Temiz İngilizce periyot adı — kart başlığı için ("Weekly"/"Monthly"/"Yearly").
    private static func periodName(for product: StoreProduct) -> String {
        guard let period = product.subscriptionPeriod else { return "" }
        switch period.unit {
        case .day:   return period.value == 7 ? "Weekly" : "Daily"
        case .week:  return "Weekly"
        case .month: return period.value == 12 ? "Yearly" : "Monthly"
        case .year:  return "Yearly"
        @unknown default: return ""
        }
    }

    /// Ürünün abonelik periyodundan etiket ("/week", "/month", "/year").
    private static func periodLabel(for product: StoreProduct) -> String? {
        guard let period = product.subscriptionPeriod else { return nil }
        switch period.unit {
        case .day:   return period.value == 7 ? "/week" : "/day"
        case .week:  return "/week"
        case .month: return period.value == 12 ? "/year" : "/month"
        case .year:  return "/year"
        @unknown default: return nil
        }
    }

    /// Bir abonelik periyodunun kaç haftaya denk geldiği.
    private static func weeks(in period: RevenueCat.SubscriptionPeriod) -> Decimal? {
        switch period.unit {
        case .day:   return Decimal(period.value) / 7
        case .week:  return Decimal(period.value)
        case .month: return Decimal(period.value) * 52 / 12
        case .year:  return Decimal(period.value) * 52
        @unknown default: return nil
        }
    }

    /// Haftalık eşdeğer ham fiyat (tasarruf % hesabı + "/hafta" metni için).
    private static func perWeekValue(for product: StoreProduct) -> Decimal? {
        guard let period = product.subscriptionPeriod, let w = weeks(in: period), w > 0
        else { return nil }
        return (product.price as Decimal) / w
    }

    /// Haftadan uzun paketler için "₺28,85 / hafta" metni (haftalıkta nil).
    private static func weeklyEquivalent(for product: StoreProduct) -> String? {
        guard let period = product.subscriptionPeriod, let w = weeks(in: period), w > 1,
              let perWeek = perWeekValue(for: product) else { return nil }
        _ = period
        let fmt = NumberFormatter()
        fmt.numberStyle = .currency
        fmt.currencyCode = product.currencyCode
        guard let str = fmt.string(from: perWeek as NSDecimalNumber) else { return nil }
        return String(format: "%@ / week", str)
    }
    #endif
}
