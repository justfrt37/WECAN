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
import OSLog
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
    /// Abonelik mi, tek seferlik paket mi. StoreKit ürününün KENDİSİNDEN
    /// (`subscriptionPeriod`) türetiliyor — sunucudan gelen katalogdan DEĞİL.
    /// Sebebi: katalog asenkron yükleniyor; satın alma yönlendirmesini ona
    /// bağlamak, katalog henüz gelmemişken token paketini abonelik dalına
    /// sokuyordu (bkz. kullanıcı raporu: "token_100 alınca 12000 ekleniyor" —
    /// abonelik dalı kullanıcının eski sandbox aboneliğinin dönem grant'ını
    /// veriyordu). Ürün tipi cihazda, senkron ve her zaman doğru.
    let isSubscription: Bool
    #if canImport(RevenueCat)
    let rcPackage: Package
    #endif

    /// `periodName`'in yerelleştirilmiş gösterim hâli — kart UI'ında bunu kullanın,
    /// `periodName`'in kendisi karşılaştırma anahtarı olarak kullanıldığı için
    /// (bkz. renewalPhrase) sabit İngilizce kalmalı.
    var localizedPeriodName: String {
        switch periodName {
        case "Weekly":  return String(localized: "Weekly")
        case "Daily":   return String(localized: "Daily")
        case "Monthly": return String(localized: "Monthly")
        case "Yearly":  return String(localized: "Yearly")
        default:        return periodName
        }
    }

    /// `periodLabel`'ın yerelleştirilmiş gösterim hâli.
    var localizedPeriodLabel: String? {
        switch periodLabel {
        case "/week":  return String(localized: "/week")
        case "/day":   return String(localized: "/day")
        case "/month": return String(localized: "/month")
        case "/year":  return String(localized: "/year")
        default:       return periodLabel
        }
    }
}

/// NOT: Eski `PlummCatalog` (ürün id -> token/tier sabit tabloları) KALDIRILDI.
/// Para karşılığı verilen miktarın istemcide ikinci bir kopyasının durması,
/// sunucudaki tabloyla kayması ve kullanıcının satın aldığından farklı miktar
/// alması riskini taşıyordu. Tek kaynak artık sunucuda
/// (supabase/functions/_shared/catalog.ts); istemci GÖSTERİM için
/// `CatalogService.shared`den okur, grant miktarını asla belirlemez
/// (bkz. functions/purchase-tokens).

/// Üç ödemeli seviye — entitlement kimlikleri RevenueCat dashboard'daki
/// (henüz kurulmamış) "pro"/"pro_plus"/"max" entitlement'larıyla VE
/// `subscriptions.tier` check constraint'iyle (bkz. 005_token_system.sql)
/// AYNI kalmalı, biri değişirse diğeri de güncellenmeli.
enum SubscriptionTier: String {
    case none, pro, proPlus, max

    /// Sıralama: none < pro < proPlus < max. Paywall'da zaten aboneliği olan
    /// kullanıcıya sadece DAHA YÜKSEK tier'ları göstermek için (bkz. kullanıcı
    /// talebi — kendi sahip olduğu ya da daha düşük bir planı tekrar görmesin).
    var rank: Int {
        switch self {
        case .none: return 0
        case .pro: return 1
        case .proPlus: return 2
        case .max: return 3
        }
    }

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

    /// Bakiye deposu — satın alma sonrası sunucudan dönen bakiyeyi ANINDA
    /// yazmak için. `ChatViewModel.tokenStore` / `CallViewModel.tokenStore` ile
    /// aynı desen: TokenStore environment'tan geliyor, singleton değil; bağlantı
    /// açılışta kuruluyor (bkz. PlummApp).
    weak var tokenStore: TokenStore?

    private(set) var isConfigured = false

    /// Tier SUNUCUDAN en az bir kez okundu mu (başarılı ya da başarısız).
    /// Paywall gibi "PRO mu değil mi" kararına bağlı ekranlar bunu beklemeli:
    /// açılışta tier `.none` başlıyor ve sunucu cevabı gelene kadar öyle
    /// kalıyor, bu yüzden erken sorulduğunda PRO kullanıcı da non-PRO
    /// görünüyordu (bkz. kullanıcı raporu: "adam pro ise paywall açılmamalı").
    private(set) var tierResolved = false
    private var tierWaiters: [CheckedContinuation<Void, Never>] = []

    private func markTierResolved() {
        guard !tierResolved else { return }
        tierResolved = true
        let waiters = tierWaiters
        tierWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Tier sunucudan okunana kadar bekler. `timeout` saniye içinde cevap
    /// gelmezse yine de döner — ağ tıkalıyken kullanıcıyı süresiz bekletmek,
    /// paywall'ı yanlış açmaktan daha kötü olurdu.
    func ensureTierResolved(timeout: TimeInterval = 3) async {
        if tierResolved { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { c in
                    if self.tierResolved { c.resume() } else { self.tierWaiters.append(c) }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            }
            await group.next()
            group.cancelAll()
        }
    }
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
            await refreshEntitlement()   // yalnızca tanılama logu
            // PRO durumunun kaynağı SUNUCU. logIn'den SONRA çağrılıyor ki
            // sorgu doğru kullanıcıya ait olsun.
            await refreshServerTier()
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
            logOfferings(offerings)
        } catch {
            PurchaseService.diag.error("[PW-DIAG] offerings HATA: \(String(describing: error), privacy: .public)")
        }
        #endif
    }

    #if canImport(RevenueCat)
    /// RevenueCat'ten GERÇEKTE ne geldiğini satır satır loglar.
    ///
    /// Neden ayrıntılı: bir offering'in "boş" gelmesiyle "hiç var olmaması"
    /// farklı sorunlar. RC bir ürünü ancak App Store Connect'ten çekebilirse
    /// paketin içinde döndürür — ASC'de fiyatı/metadata'sı eksikse ya da Paid
    /// Applications Agreement aktif değilse offering döner ama paket listesi
    /// BOŞ olur. Bu log ikisini ayırt ettiriyor: `paket=0` = ASC'den çekilemedi,
    /// offering'in hiç listelenmemesi = RC dashboard'da yok.
    private func logOfferings(_ offerings: Offerings) {
        let current = offerings.current?.identifier ?? "yok"
        PurchaseService.diag.log("""
            [PW-DIAG] offerings yüklendi offeringSayısı=\(offerings.all.count, privacy: .public) \
            current=\(current, privacy: .public) \
            eşlenen: pro=\(self.proPackages.count, privacy: .public) \
            plus=\(self.proPlusPackages.count, privacy: .public) \
            max=\(self.maxPackages.count, privacy: .public) \
            tokens=\(self.tokenPackages.count, privacy: .public)
            """)
        for (key, offering) in offerings.all.sorted(by: { $0.key < $1.key }) {
            let pkgs = offering.availablePackages
            PurchaseService.diag.log("[PW-DIAG]   offering '\(key, privacy: .public)' paket=\(pkgs.count, privacy: .public)")
            for pkg in pkgs {
                let p = pkg.storeProduct
                PurchaseService.diag.log("""
                    [PW-DIAG]     \(pkg.identifier, privacy: .public) -> \
                    \(p.productIdentifier, privacy: .public) \
                    fiyat=\(p.localizedPriceString, privacy: .public) \
                    başlık='\(p.localizedTitle, privacy: .public)' \
                    token=\(CatalogService.shared.tokens(for: p.productIdentifier), privacy: .public)
                    """)
            }
            if pkgs.isEmpty {
                PurchaseService.diag.log("[PW-DIAG]     (boş — ürünler App Store Connect'ten ÇEKİLEMEDİ)")
            }
        }
        // Kodun beklediği ama RC'nin döndürmediği ürünler: paywall'da eksik
        // satır olarak görünürler, sebebi burada isimle yazılı olsun.
        let gelen = Set(offerings.all.values.flatMap { $0.availablePackages }.map { $0.storeProduct.productIdentifier })
        let beklenen = Set(CatalogService.shared.productTier.keys).union(CatalogService.shared.tokenPacks.keys)
        let eksik = beklenen.subtracting(gelen).sorted()
        if !eksik.isEmpty {
            PurchaseService.diag.log("[PW-DIAG]   EKSİK (katalogda var, RC'den gelmedi): \(eksik.joined(separator: ","), privacy: .public)")
        }
    }

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
                tokenAmount: CatalogService.shared.tokens(for: p.productIdentifier),
                isSubscription: p.subscriptionPeriod != nil,
                rcPackage: pkg
            )
        }
        .sorted { $0.priceValue < $1.priceValue }
    }
    #endif

    /// Satın almanın kullanıcıya GÖSTERİLEBİLİR sonucu.
    ///
    /// Eskiden `purchase(_:)` yalnızca `Bool` dönüyordu: iptal, ağ hatası,
    /// mağaza reddi ve "ödeme alındı ama token yazılamadı" hepsi aynı `false`
    /// idi ve ekranda hiçbir şey görünmüyordu. Kullanıcının parası gidip
    /// token'ı gelmediğinde bunu FARK ETMESİ gerekiyor (bkz. kullanıcı talebi).
    enum PurchaseOutcome {
        /// Satın alma tamam ve sunucu `granted` kadar token yazdı.
        /// `granted == 0` abonelikler için normaldir (token dönem grant'ıyla gelir).
        case success(granted: Int)
        /// Kullanıcı App Store diyaloğunu kapattı — hata DEĞİL, mesaj gösterilmez.
        case cancelled
        /// Mağaza reddetti ya da istek patladı.
        case failed(String)
        /// Ödeme alındı ama sunucu token'ı yazamadı (ağ/sunucu hatası).
        /// En kritik durum: kullanıcıya "restore ile geri gelir" denmeli,
        /// sessizce yutulmamalı.
        case paidButNotGranted
    }

    /// `purchaseDetailed`in geriye-uyumlu sarmalayıcısı — mevcut paywall
    /// çağrıları (OnboardingPaywallView, SubscriptionPaywallView) değişmeden
    /// derlensin diye duruyor.
    @discardableResult
    func purchase(_ package: PaywallPackage) async -> Bool {
        if case .success = await purchaseDetailed(package) { return true }
        return false
    }

    /// Seçili paketi satın alır ve sonucu AYRINTILI döner (bkz. PurchaseOutcome).

    func purchaseDetailed(_ package: PaywallPackage) async -> PurchaseOutcome {
        #if canImport(RevenueCat)
        guard isConfigured else { return .failed("Store is not ready yet.") }
        // configure()'daki logIn, uid henüz yazılmamışken (uygulama açılış
        // yarışı) sessizce atlanmış olabilir — burada, kullanıcı gerçekten bir
        // satın alma yaptığı an, uid KESİN mevcut, o yüzden tekrar deneriz.
        // logIn idempotent, aynı id'yle tekrar çağırmak zararsız.
        if let uid = UserDefaultsManager.shared.userId, Purchases.shared.appUserID != uid {
            _ = try? await Purchases.shared.logIn(uid)
        }
        do {
            let result = try await Purchases.shared.purchase(package: package.rcPackage)
            guard !result.userCancelled else { return .cancelled }

            if !package.isSubscription {
                // Token PAKETİ (consumable): entitlement/subscription üretmez.
                // Grant'ı SUNUCU yapar (purchase-tokens): RC'nin
                // non_subscriptions kaydını secret key ile doğrular, miktarı
                // KENDİ kataloğundan okur ve mağaza işlem kimliğiyle idempotent
                // yazar. Eskiden bu `#if DEBUG` içindeydi — yani Release/
                // TestFlight'ta satın alma HİÇ token vermiyordu (bkz. kullanıcı
                // raporu: "100 token alıyorum ama gelmiyor").
                // SADECE bu satın almanın işlem kimliği gönderiliyor: sunucu
                // yalnızca onu doğrulayıp verir. Kimlik göndermezsek sunucu
                // RC'deki TÜM geçmiş tek-seferlik satın almaları toparlıyor —
                // bu, bir token_100 alımında geçmişteki ödenmiş ama hiç
                // verilmemiş paketlerin de aynı anda yüklenmesine yol açıyordu
                // (canlı örnek: 4x100 + 2x5000 = 10.400, bkz. kullanıcı raporu).
                let granted = await grantTokenPackFromServer(
                    transactionId: result.transaction?.transactionIdentifier
                )
                guard let granted else { return .paidButNotGranted }
                return .success(granted: granted)
            } else {
                // Abonelik: tier'ı SUNUCU belirler. syncWithServerRetrying →
                // sync-subscription, RC'yi secret key ile sunucuda doğrulayıp
                // `subscriptions` satırını yazar ve tier'ı yanıtından set eder.
                // refreshEntitlement yalnızca tanılama logu basar.
                await refreshEntitlement()
                await syncWithServerRetrying()
                #if DEBUG
                // Simülatör: RC yerel StoreKit Testing satın almalarını sunucuya
                // KAYDETMEZ → syncWithServer boş döner. Aktif aboneliği StoreKit'ten
                // bulup ürüne özel token'ı dev-token-tools ile ver (dönem-idempotent).
                if tier == .none { await debugGrantFromStoreKit() }
                #endif
            }
            // Abonelik: token'ı dönem grant'ı veriyor, burada 0 doğru.
            return .success(granted: 0)
        } catch {
            PurchaseService.diag.error("[PW-DIAG] purchase hatası: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
        #else
        return .failed("Store is not available in this build.")
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
        await refreshEntitlement()      // yalnızca tanılama logu
        await syncWithServerRetrying()  // tier'ı sunucu doğrular ve yazar
        // Token PAKETLERİ için kurtarma yolu: satın alma anındaki
        // grantTokenPackFromServer çağrısı ağ hatası ya da uygulamanın
        // öldürülmesi yüzünden hiç tamamlanmamış olabilir — o durumda ödeme
        // alınmış ama token verilmemiş olurdu ve başka hiçbir şey bunu
        // telafi etmezdi (consumable entitlement üretmediği için webhook da
        // devreye girmiyor). purchase-tokens mağaza işlem kimliğiyle
        // idempotent olduğu için burada tekrar çağırmak zararsız: işlenmiş
        // satın almalar için 0 token verir, atlanmış olan varsa onu verir.
        await grantTokenPackFromServer(maxAttempts: 1)
        #if DEBUG
        // Simülatörde restore: RC sunucusu yerel satın almayı görmediğinden
        // syncWithServer boş döner. StoreKit'teki aktif aboneliği bulup grant et
        // (idempotent — aynı dönemde token EKLEMEZ).
        if tier == .none { await debugGrantFromStoreKit() }
        #endif
        #endif
        return isPro
    }

    /// `syncWithServer()`'ın TEK seferlik çağrısı, RC'nin sunucu tarafı
    /// (secret key ile GET /subscribers) satın almayı henüz işlememiş olduğu
    /// dar pencereye denk gelirse token grant'ı SESSİZCE hiç olmuyordu — ne
    /// retry ne de webhook (o da eninde sonunda gelir ama satın alma anında
    /// kullanıcı bekliyor) bunu telafi ediyordu (bkz. kullanıcı talebi —
    /// "satın alımda token eklenmiyor"). Kısa aralıklarla birkaç kez dener,
    /// sunucu bir tier doğrular doğrulamaz durur.
    /// Token paketi satın alması → `purchase-tokens`. Sunucu RC'yi doğrular,
    /// miktarı kendi kataloğundan okur, mağaza işlem kimliğiyle idempotent
    /// yazar ve GÜNCEL BAKİYEYİ döner.
    ///
    /// İstemci hiçbir yerde miktar GÖNDERMİYOR ve bakiyeyi kendi HESAPLAMIYOR:
    /// ekrandaki sayı doğrudan sunucunun döndüğü değere yazılıyor, böylece
    /// arayüzle veritabanı ayrışamıyor ("ne eksik ne fazla").
    ///
    /// Satın alma RC'ye ulaşmadan biz sorarsak (dar yayılım penceresi) grant 0
    /// döner — bu yüzden birkaç kez, aralıklı denenir; token gelir gelmez durur.
    /// `transactionId` verilirse sunucu YALNIZCA o işlemi işler ("ne eksik ne
    /// fazla"). `nil` ise (restore akışı) RC'deki tüm tek-seferlik satın
    /// almaları tarar — restore'un amacı zaten ödenmiş ama verilmemiş olanı
    /// geri getirmek.
    /// Dönüş: sunucunun bu çağrıda verdiği token. `nil` = sunucuya hiç
    /// ulaşılamadı (ağ/HTTP hatası) — "0 token verildi"den farklı, çünkü
    /// ilkinde satın alma hâlâ kurtarılabilir (restore), ikincisinde işlem
    /// zaten işlenmiştir.
    @discardableResult
    private func grantTokenPackFromServer(transactionId: String? = nil,
                                          maxAttempts: Int = 4,
                                          delaySeconds: UInt64 = 2) async -> Int? {
        guard let accessToken = UserDefaultsManager.shared.accessToken,
              let url = URL(string: "\(Config.supabaseURL)/functions/v1/purchase-tokens")
        else { return nil }
        struct GrantResponse: Decodable { let granted: Int; let balance: Int }
        var lastGranted: Int?
        for attempt in 1...maxAttempts {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let payload: [String: Any] = transactionId.map { ["transactionId": $0] } ?? [:]
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let decoded = try? JSONDecoder().decode(GrantResponse.self, from: data)
            else {
                PurchaseService.diag.log("[PW-DIAG] token grant deneme \(attempt, privacy: .public): istek başarısız")
                if attempt < maxAttempts { try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000) }
                continue
            }
            // Bakiye her durumda sunucudan yazılır (grant 0 olsa bile) —
            // böylece ekran her zaman veritabanıyla aynı.
            self.tokenStore?.setBalance(decoded.balance)
            PurchaseService.diag.log("""
                [PW-DIAG] token grant deneme \(attempt, privacy: .public): \
                +\(decoded.granted, privacy: .public) bakiye=\(decoded.balance, privacy: .public)
                """)
            if decoded.granted > 0 { return decoded.granted }
            if attempt < maxAttempts { try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000) }
            lastGranted = decoded.granted
        }
        return lastGranted
    }

    /// Sabit 2sn x 4 deneme (~8sn) yetmiyordu: RevenueCat makbuzu işleyip
    /// entitlement'ı yayınlaması bazen bundan uzun sürüyor (canlı örnek:
    /// Pro -> Pro+ yükseltmesi ancak ~3 dakika sonra düştü). Pencere
    /// dolduğunda istemci pes ediyor ve tier eski kalıyordu.
    ///
    /// Artan bekleme ile ~60 saniyeye çıkarıldı. Sabit kısa aralıkla 30 kez
    /// denemek yerine artan aralık: ilk saniyelerde hızlı yakalar (yaygın
    /// durum), geç kalan yayılımı da sunucuyu gereksiz yormadan bekler.
    private static let syncBackoff: [UInt64] = [1, 2, 3, 5, 8, 12, 15, 15]

    private func syncWithServerRetrying() async {
        for (i, wait) in Self.syncBackoff.enumerated() {
            if await syncWithServer() { return }
            if i < Self.syncBackoff.count - 1 {
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            }
        }
        PurchaseService.diag.log("[PW-DIAG] sync: pencere doldu, tier sunucudan doğrulanamadı")
    }

    /// Sunucu tarafı token ekonomisine köprü. `sync-subscription` edge
    /// function'ını çağırır: RC entitlement'ı secret key ile SUNUCUDA doğrulanır,
    /// `subscriptions` satırı upsert edilir ve tier'ın haftalık token'ları verilir
    /// (aynı dönemde tekrar çağrılınca yeniden vermez). `tier`'ı sunucu yanıtına
    /// göre günceller, yeni token bakiyesini döndürür (TokenStore.refresh için).
    /// Dönüş değeri: sunucu BU çağrıda aktif bir tier doğruladı mı (token
    /// grant'ı gerçekten oldu mu) — `purchase()`/`restore()`'daki retry
    /// döngüsü bunu "artık durabiliriz" sinyali olarak kullanır.
    @discardableResult
    func syncWithServer() async -> Bool {
        #if canImport(RevenueCat)
        guard isConfigured,
              let accessToken = UserDefaultsManager.shared.accessToken,
              let url = URL(string: "\(Config.supabaseURL)/functions/v1/sync-subscription")
        else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let appUserId = Purchases.shared.appUserID
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["appUserId": appUserId])
        struct SyncResponse: Decodable { let tier: String?; let balance: Int? }
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            print("[PW-DIAG] sync ağ hatası")
            return false
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        print("[PW-DIAG] sync appUserId=\(appUserId) status=\(status) body=\(String(data: data, encoding: .utf8) ?? "")")
        guard (200..<300).contains(status),
              let decoded = try? JSONDecoder().decode(SyncResponse.self, from: data)
        else { return false }
        // "Tier yok" yanıtı burada tier'ı DÜŞÜRMEZ — ama artık farklı bir
        // gerekçeyle: bu çağrı satın alma/restore anındaki RETRY döngüsünün
        // içinde (bkz. syncWithServerRetrying). RC→sunucu doğrulaması o dar
        // pencerede henüz tamamlanmamış olabilir ve her denemede tier'ı .none'a
        // çekmek, az önce ödeme yapmış kullanıcıya paywall'ı tekrar açtırırdı
        // (bkz. kullanıcı talebi). Nihai söz `refreshServerTier()`'da: o,
        // `subscriptions` tablosunu okur ve satır yoksa tier'ı .none yapar.
        switch decoded.tier {
        case "max":      tier = .max; return true
        case "pro_plus": tier = .proPlus; return true
        case "pro":      tier = .pro; return true
        default:         return false
        }
        #else
        return false
        #endif
    }

    #if DEBUG
    /// Satın alınan ürün id'sinden tier çıkarır (katalogdan).
    private func tier(forProductId productId: String) -> SubscriptionTier {
        CatalogService.shared.tier(for: productId)
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
        CatalogService.shared.tokens(for: productId)
    }

    /// RC'nin ne düşündüğünü YALNIZCA LOGLAR — `tier`'a ARTIK DOKUNMAZ.
    ///
    /// Eskiden PRO durumunun kaynağı burasıydı (`entitlements["max"/"pro_plus"/
    /// "pro"]`). Sorun: RC istemcinin gördüğü makbuza dayanıyor ve iptal/iade
    /// edilmiş ya da temizlenmiş sandbox satın almalarını, kaydettiği bitiş
    /// tarihine kadar "aktif" saymaya devam ediyor. Apple tarafında sandbox
    /// geçmişi TEMİZLENDİKTEN sonra bile RC üç entitlement'ı aktif vermeye devam
    /// etti ve uygulama, sunucuda hiçbir abonelik satırı olmamasına rağmen
    /// (`body=[]`) Max göründü (bkz. kullanıcı talebi: "pro olup olmama durumunu
    /// RC'den okuma, backend'den oku").
    ///
    /// Artık tek doğruluk kaynağı sunucudaki `subscriptions` tablosu
    /// (bkz. refreshServerTier / syncWithServer). Sunucu tarafı zaten RC'yi
    /// SECRET key ile kendi doğruluyor — istemcinin RC'ye güvenmesi hem
    /// gereksiz hem de istemci tarafı makbuz durumuna açık.
    func refreshEntitlement() async {
        #if canImport(RevenueCat)
        guard isConfigured else {
            PurchaseService.diag.log("[PW-DIAG] entitlement: RC yapılandırılmadı, tier korunuyor (\(self.tier.rawValue, privacy: .public))")
            return
        }
        guard let info = try? await Purchases.shared.customerInfo() else {
            PurchaseService.diag.log("[PW-DIAG] entitlement: customerInfo ALINAMADI, tier korunuyor (\(self.tier.rawValue, privacy: .public))")
            return
        }
        // Hangi entitlement'ın AKTİF olduğu, sunucuyla UYUŞMAZLIK olduğunda
        // teşhisi tek başına verir — RC'de kalmış eski sandbox satın almaları
        // burada görünür (bkz. kullanıcı talebi: pro olmadığı halde pro görünmesi).
        let active = info.entitlements.all
            .filter { $0.value.isActive }
            .map { "\($0.key)(\($0.value.productIdentifier))" }
            .sorted()
            .joined(separator: ",")
        PurchaseService.diag.log("""
            [PW-DIAG] entitlement kaynak=RevenueCat (SALT TANILAMA, tier yazmaz) \
            appUserId=\(Purchases.shared.appUserID, privacy: .public) \
            aktif=[\(active.isEmpty ? "yok" : active, privacy: .public)] \
            mevcutTier=\(self.tier.rawValue, privacy: .public) isPro=\(self.isPro, privacy: .public)
            """)
        #endif
    }

    /// Tanılama kanalı. `print` yerine `Logger`: print YALNIZCA Xcode'a
    /// bağlıyken görünür, bu ise TestFlight/Release'te de Console.app'ten
    /// (cihaz bağlı, alt sistem filtresi `com.firat.Plumm`) okunabilir —
    /// PRO durumu asıl orada teşhis ediliyor.
    /// Interpolasyonlar açıkça `.public`: Logger varsayılanı dinamik değerleri
    /// `<private>` diye maskeler, o da logu işe yaramaz hale getirirdi. Burada
    /// yalnızca kimlik/tier bilgisi basılıyor — access token, refresh token
    /// veya makbuz ASLA loglanmıyor.
    static let diag = Logger(subsystem: "com.firat.Plumm", category: "purchase")

    /// Kullanıcının o anki hak durumunun TEK SATIRLIK özeti. Uygulamanın
    /// herhangi bir yerinden çağrılabilir; tier'ı değiştirmez, sadece raporlar.
    func logEntitlementState(_ context: String) {
        var line = "[PW-DIAG] durum(\(context)) tier=\(tier.rawValue) isPro=\(isPro) canUseVoice=\(canUseVoice)"
        line += " supabaseUid=\(UserDefaultsManager.shared.userId ?? "yok")"
        line += " rcConfigured=\(isConfigured)"
        #if canImport(RevenueCat)
        if isConfigured { line += " rcAppUserId=\(Purchases.shared.appUserID)" }
        #endif
        PurchaseService.diag.log("\(line, privacy: .public)")
    }

    /// Sunucudaki `subscriptions` tablosundan tier'ı okur. Token ekonomisinin
    /// gerçek kaynağı sunucu olduğu için (özellikle simülatörde RC entitlement'ı
    /// boşken), açılışta `isPro`/tier'ın DOĞRU görünmesini bu sağlar — kullanıcı
    /// restore'a basmadan pro olduğunu bilir. Sunucuda satır yoksa tier düşürülmez
    /// (RC entitlement'ı geçerliyse korunur).
    func refreshServerTier() async {
        // Hangi yoldan çıkarsak çıkalım (oturum yok / ağ hatası / başarı)
        // bekleyenler serbest bırakılmalı, yoksa paywall süresiz beklerdi.
        defer { markTierResolved() }
        let uid = UserDefaultsManager.shared.userId ?? "yok"
        // `current_period_end >= now` filtresi ŞART: sorgu bunsuz, süresi
        // DOLMUŞ bir aboneliğin tier'ını da döndürüyordu. Sunucu tarafı her
        // yerde bu filtreyle bakıyor (entitlements.ts activeTier,
        // create-character), yani istemci "Max'im" derken sunucu sesli
        // aramayı/karakter yaratmayı reddediyordu — ve PRO butonu, yükseltecek
        // yer olmadığı sanılarak gizli kalıyordu.
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let encodedNow = nowISO.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? nowISO
        guard let accessToken = UserDefaultsManager.shared.accessToken,
              let url = URL(string: "\(Config.supabaseURL)/rest/v1/subscriptions?select=tier&current_period_end=gte.\(encodedNow)")
        else {
            PurchaseService.diag.log("[PW-DIAG] serverTier: oturum yok, atlandı (uid=\(uid, privacy: .public))")
            return
        }
        var req = URLRequest(url: url)
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else {
            PurchaseService.diag.log("[PW-DIAG] serverTier: istek BAŞARISIZ, tier korunuyor (\(self.tier.rawValue, privacy: .public))")
            return
        }
        // Ham gövde de basılıyor: boş dizi `[]` ile `[{"tier":"max"}]` arasındaki
        // fark, "sunucuda satır yok ama uygulama PRO görünüyor" durumunu tek
        // bakışta ayırt ettiriyor (bkz. kullanıcı talebi).
        let body = String(data: data, encoding: .utf8) ?? "<okunamadı>"
        struct Row: Decodable { let tier: String }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else {
            PurchaseService.diag.log("[PW-DIAG] serverTier: gövde çözümlenemedi status=\(http.statusCode, privacy: .public) body=\(body, privacy: .public)")
            return
        }
        let before = tier
        // İSTEK BAŞARILI + SATIR YOK = kullanıcının aboneliği yok. Sunucu tek
        // doğruluk kaynağı olduğu için burada tier DÜŞÜRÜLÜR. (Eskiden "satır
        // yoksa dokunma" idi; RC tier'ı yazdığı için bu bir güvenlik ağıydı.
        // Artık RC tier yazmadığından o ağ gereksiz — ve tam da o yüzden
        // sunucuda kayıt olmadan Max görünüyordu.) Ağ/HTTP hatasında yukarıdaki
        // guard'lar erken dönüyor, yani ÇEVRİMDIŞIYKEN tier düşmez.
        guard let t = rows.first?.tier else {
            tier = .none
            PurchaseService.diag.log("""
                [PW-DIAG] serverTier kaynak=Supabase uid=\(uid, privacy: .public) \
                status=\(http.statusCode, privacy: .public) body=\(body, privacy: .public) \
                satır YOK -> tier \(before.rawValue, privacy: .public)->none, isPro=false
                """)
            return
        }
        switch t {
        case "max":      tier = .max
        case "pro_plus": tier = .proPlus
        case "pro":      tier = .pro
        default:         tier = .none
        }
        PurchaseService.diag.log("""
            [PW-DIAG] serverTier kaynak=Supabase uid=\(uid, privacy: .public) \
            status=\(http.statusCode, privacy: .public) body=\(body, privacy: .public) \
            tier \(before.rawValue, privacy: .public)->\(self.tier.rawValue, privacy: .public) \
            isPro=\(self.isPro, privacy: .public)
            """)
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
    // NOT: dönüş değeri hem UI'da gösteriliyor HEM DE renewalPhrase() gibi yerlerde
    // switch-case karşılaştırma anahtarı olarak kullanılıyor — burada localize
    // ETMEYİN, o zaman karşılaştırmalar kırılır. Gösterim tarafında
    // `localizedPeriodName`/`localizedPeriodLabel` kullanın (bkz. planCard).
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
