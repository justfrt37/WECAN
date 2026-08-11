//
//  OnboardingPaywallView.swift
//  ONB6 — abonelik paywall'ı. "O bekliyor" ekranından sonra gelir.
//  Arka planda ONB3'te seçilen kızın videosu (bulanık) oynar — "kilidini aç"
//  fikrini pekiştirir. Pencil "PAYWALL" mockup'ının uygulama karşılığı.
//

import SwiftUI

struct OnboardingPaywallView: View {
    @Environment(OnboardingStore.self) private var onboarding
    @Environment(\.dismiss) private var dismiss

    /// X (kapat) butonu 2 sn sonra belirir — kullanıcı önce paywall'ı görsün.
    @State private var showClose = false

    /// Yasal metinler UYGULAMA İÇİNDE açılır (dış tarayıcı/host'a bağımlı değil,
    /// bkz. LegalDocumentView) — App Review linklerin çalıştığını görmeli.
    @State private var legalDocument: LegalDocument?

    /// Kapatma: bir cover olarak (PRO butonundan) açıldıysa dismiss() yeter.
    /// Onboarding'in son adımı olarak açıldıysa (isCompleted henüz false) —
    /// ONB3'te seçilen kızın chat'ine girilir; onboarding TAM DA chat görününce
    /// complete olur (bkz. MainTabView.openPendingOnboardingChat). Seçim yoksa
    /// doğrudan tamamla.
    private func close() {
        dismiss()
        if !onboarding.isCompleted, let name = onboarding.selectedCharacter?.chatCharacterName {
            onboarding.pendingChatCharacterName = name
        } else {
            onboarding.complete()
        }
    }

    /// RevenueCat paketleri (ucuzdan pahalıya) buradan gelir; seçili paket id'si.
    /// Varsayılan seçim en pahalı (en avantajlı) paket — `packages.last`.
    @Environment(TokenStore.self) private var tokenStore
    @State private var purchases = PurchaseService.shared
    @State private var selectedTier: SubscriptionTier
    @State private var selectedPackageID: String?
    @State private var isPurchasing = false

    /// Hangi gate bu paywall'ı açtırdıysa o tier ön-seçili gelsin (ör. voice
    /// gate → Pro+) — yoksa zaten Pro sahibi biri voice engellenince kendi
    /// SAHİP OLDUĞU Pro paketini tekrar tekrar görüyordu (bkz. kullanıcı
    /// talebi — "paywall şurada tekrar tekrar çıkıyor").
    init(preselectedTier: SubscriptionTier = .pro) {
        _selectedTier = State(initialValue: preselectedTier)
    }

    private let tiers: [(tier: SubscriptionTier, label: String)] = [
        (.pro, "Pro"), (.proPlus, "Pro+"), (.max, "Pro Max"),
    ]

    private var packages: [PaywallPackage] { purchases.packages(for: selectedTier) }
    private var selectedPackage: PaywallPackage? {
        packages.first { $0.id == selectedPackageID } ?? packages.last
    }
    /// En pahalı paketin haftalık eşdeğerine göre tasarruf yüzdesi ("80% OFF").
    private func savingsBadge(for pkg: PaywallPackage) -> String {
        let maxPerWeek = packages.compactMap(\.perWeekValue).max()
        if let mine = pkg.perWeekValue, let top = maxPerWeek, top > 0, mine < top {
            let pct = ((1 - mine / top) as NSDecimalNumber).doubleValue * 100
            return String(format: "%d%% OFF", Int(pct.rounded()))
        }
        return "Best Value"
    }

    /// Arkada oynayacak video — ONB3'te seçilen kızınki (yoksa varsayılan).
    private var bgVideo: String {
        onboarding.selectedCharacter?.selectedVideo ?? "onb4Video"
    }

    /// Tik'li özellik listesi — tier'a göre DEĞİŞEN kısımlar üstte (jeton,
    /// karakter hakkı, ses), her tier'da AYNI olanlar altta. İş kuralları
    /// sunucuda tanımlı (supabase/functions/_shared/entitlements.ts); buradaki
    /// metinler `SubscriptionTier` aynasından üretilir ki ikisi ayrışmasın.
    private func features(for tier: SubscriptionTier) -> [String] {
        var list: [String] = []

        // 1) Jeton — seçili süreye göre değiştiği için seçili paketten okunur
        //    (yıllıkta 12.000, haftalıkta 250 vb.); paket henüz yüklenmediyse
        //    atlanır. Jeton her dönem YENİLENİR (tek seferlik değil, bkz.
        //    sync-subscription dönem grant'ı) — metin bunu açıkça söylüyor.
        if let pkg = selectedPackage, pkg.tokenAmount > 0 {
            list.append("\(pkg.tokenAmount.formatted()) renewable coins, \(Self.renewalPhrase(pkg.periodName))")
        }

        // 2) Karakter yaratma hakkı — Pro 1, Pro+ 5, Pro Max sınırsız.
        switch tier.weeklyCharacterSlots {
        case nil:
            list.append("Unlimited character creation")
        case 1:
            list.append("Create 1 character per week")
        case let slots?:
            list.append("Create \(slots) characters per week")
        }

        // 3) Ses — Pro'da YOK, kalanlarda var. Yoksa listeye hiç eklenmez
        //    (tik'li listede "yok" satırı göstermek kafa karıştırır).
        if tier.canUseVoice {
            list.append("Voice messages & voice calls")
        }

        // 4) Her tier'da aynı olanlar.
        list.append(contentsOf: [
            "Unlimited photos",
            "Unlimited access (24/7)",
            "Long-term memory",
        ])
        return list
    }

    /// Yenilenme sıklığı — `PaywallPackage.periodName` ("Weekly"/"Monthly"/
    /// "Yearly") karşılığı. Periyot bilinmiyorsa dönem-nötr ("every period")
    /// döner, yanlış bir süre uydurmaz.
    private static func renewalPhrase(_ periodName: String) -> String {
        switch periodName {
        case "Weekly":  return String(localized: "every week")
        case "Monthly": return String(localized: "every month")
        case "Yearly":  return String(localized: "every year")
        default:        return String(localized: "every period")
        }
    }

    var body: some View {
        ZStack {
            // Seçilen kızın videosu — bulanık + karartma ("kilidini aç" hissi).
            LoopingVideoPlayer(resourceName: bgVideo)
                .id(bgVideo)
                .ignoresSafeArea()
                .blur(radius: 6)
                .overlay(scrim.ignoresSafeArea())

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                content
            }

            // Satın alma / geri yükleme sürerken: düşük-opacity siyah gradient +
            // ortada dönen loading. İşlem cevabı gelince kalkar.
            if isPurchasing {
                LinearGradient(
                    colors: [.black.opacity(0.35), .black.opacity(0.55)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
                .overlay {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isPurchasing)
        .task {
            if packages.isEmpty { await purchases.loadOfferings() }
        }
        .task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeIn(duration: 0.4)) { showClose = true }
        }
        .sheet(item: $legalDocument) { LegalDocumentView(document: $0) }
    }

    // MARK: Üst bar (X + logo PRO)

    private var topBar: some View {
        ZStack {
            OBBrandMarkPro()
            HStack {
                Button { close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 30, height: 30)
                }
                .opacity(showClose ? 1 : 0)
                .disabled(!showClose)
                Spacer()
            }
        }
        .padding(.horizontal, OBTheme.screenPadding)
        .padding(.top, 8)
    }

    // MARK: Alt içerik

    private var content: some View {
        VStack(spacing: 14) {
            // Özellikler (tik'li) — tier seçicinin ÜSTÜNDE.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(features(for: selectedTier), id: \.self) { f in
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color(hex: 0x34D399))
                        Text(f)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, OBTheme.screenPadding)

            tierSelector

            if packages.isEmpty {
                ProgressView().tint(.white).frame(height: 200)
            } else {
                VStack(spacing: 8) {
                    // Seçili tier'ın süre seçenekleri (dikey), en pahalıda rozet.
                    ForEach(packages) { pkg in
                        planCard(pkg, isTop: pkg.id == packages.last?.id)
                    }
                }
            }

            Button { unlock() } label: {
                Group {
                    if isPurchasing {
                        ProgressView().tint(.white)
                    } else {
                        Text("Continue").font(.system(size: 25, weight: .heavy))
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 62)
                .background(OBTheme.buttonGradient, in: RoundedRectangle(cornerRadius: 20))
            }
            .disabled(isPurchasing)

            legalRow
        }
        .padding(.horizontal, OBTheme.screenPadding)
        .padding(.bottom, 15)   // buton yere daha yakın olsun (5px daha yukarı)
    }

    /// Üstteki yatay tier seçici — Pro / Pro+ / Pro Max.
    private var tierSelector: some View {
        HStack(spacing: 2) {
            ForEach(tiers, id: \.tier) { item in
                let selected = item.tier == selectedTier
                Button {
                    selectedTier = item.tier
                    selectedPackageID = nil   // yeni tier → varsayılan (yıllık)
                } label: {
                    Text(item.label)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(selected ? .white : .white.opacity(0.7))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(selected ? OBTheme.buttonGradient : LinearGradient(colors: [.clear, .clear], startPoint: .top, endPoint: .bottom), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.10), in: Capsule())
    }

    /// Kompakt yatay süre kartı (dikey stack'e uygun) — sol periyot, sağ fiyat.
    /// Token miktarı GÖSTERİLMEZ (bkz. kullanıcı talebi). En pahalıda tasarruf rozeti.
    private func planCard(_ pkg: PaywallPackage, isTop: Bool) -> some View {
        let selected = selectedPackage?.id == pkg.id
        return Button { selectedPackageID = pkg.id } label: {
            HStack(spacing: 10) {
                Text(pkg.periodName).font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                Spacer()
                if isTop {
                    Text(savingsBadge(for: pkg))
                        .font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(OBTheme.buttonGradient, in: Capsule())
                }
                VStack(alignment: .trailing, spacing: 0) {
                    Text(pkg.localizedPrice).font(.system(size: 20, weight: .heavy)).foregroundStyle(.white)
                    if let period = pkg.periodLabel {
                        Text(period).font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .padding(.vertical, 12).padding(.horizontal, 14)
            .background(
                (selected ? OBTheme.coral.opacity(0.16) : Color.white.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(selected ? OBTheme.coral : .white.opacity(0.18), lineWidth: selected ? 2 : 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    /// "Kilidi Aç" — seçili paketi satın alır; başarılıysa onboarding'i kapatır.
    /// Paket yüklenmediyse (offering boş) akışı bloke etmemek için kapatır.
    private func unlock() {
        guard let pkg = selectedPackage else { close(); return }
        Task {
            isPurchasing = true
            let ok = await purchases.purchase(pkg)
            if ok { await tokenStore.refresh() }   // sunucu verdiği token'ları çek
            isPurchasing = false
            if ok { close() }
        }
    }

    /// Butonun altındaki yasal linkler — Privacy, Terms, Restore.
    private var legalRow: some View {
        HStack(spacing: 16) {
            Button("Privacy Policy") { legalDocument = .privacy }
            Button("Terms of Use") { legalDocument = .terms }
            Button("Restore") { restore() }
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.white.opacity(0.5))
        .buttonStyle(.plain)
    }

    private func restore() {
        Task {
            isPurchasing = true
            let ok = await purchases.restore()
            if ok { await tokenStore.refresh() }
            isPurchasing = false
            if ok { close() }
        }
    }

    /// Video üstü karartma — metni okunur kılar.
    private var scrim: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(hex: 0x0E060A, alpha: 0.30), location: 0.0),
                .init(color: Color(hex: 0x0E060A, alpha: 0.35), location: 0.35),
                .init(color: Color(hex: 0x140810, alpha: 0.82), location: 0.60),
                .init(color: Color(hex: 0x0C0509, alpha: 0.97), location: 1.0),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }
}

/// "❤ Plumm PRO" logo satırı — normal OBBrandMark + PRO rozeti.
private struct OBBrandMarkPro: View {
    var body: some View {
        HStack(spacing: 8) {
            OBBrandMark(size: 22)
            Text("PRO")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(OBTheme.buttonGradient, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
