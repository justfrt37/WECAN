//
//  SubscriptionPaywallView.swift
//  Ana abonelik paywall'u. Üstte tier seçici (Pro / Pro+ / Pro Max), seçili
//  tier'ın weekly/monthly/yearly paketleri (RevenueCat default/plus/max
//  offering'lerinden), altında tek seferlik token paketleri (tokens offering).
//

import SwiftUI

struct SubscriptionPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TokenStore.self) private var tokenStore
    @State private var purchases = PurchaseService.shared
    @State private var selectedTier: SubscriptionTier = .pro
    @State private var selectedPackageID: String?
    @State private var isPurchasing = false
    /// Satın alma sonucu mesajı. Eskiden bu ekran `purchase()`in Bool'unu
    /// kullanıyordu: iptal, mağaza hatası ve App Store kimlik doğrulama
    /// çöküşü aynı `false` idi ve ekran HİÇBİR ŞEY söylemeden kapanıyordu
    /// (bkz. PurchaseService.PurchaseOutcome.storeAuthProblem).
    @State private var resultMessage: PurchaseService.OutcomeMessage?

    private let tiers: [(tier: SubscriptionTier, label: String)] = [
        (.pro, "Pro"), (.proPlus, "Pro+"), (.max, "Pro Max"),
    ]

    private var packages: [PaywallPackage] { purchases.packages(for: selectedTier) }
    /// Seçili paket — varsayılan en pahalı (yıllık, en avantajlı).
    private var selectedPackage: PaywallPackage? {
        packages.first { $0.id == selectedPackageID } ?? packages.last
    }

    private func savingsBadge(for pkg: PaywallPackage) -> String {
        let maxPerWeek = packages.compactMap(\.perWeekValue).max()
        if let mine = pkg.perWeekValue, let top = maxPerWeek, top > 0, mine < top {
            let pct = ((1 - mine / top) as NSDecimalNumber).doubleValue * 100
            return String(format: "%d%% OFF", Int(pct.rounded()))
        }
        return String(localized: "Best Value")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [AppColor.bg2, AppColor.bg], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 18) {
                            Text("Go Premium")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.top, 12)

                            tierSelector

                            if packages.isEmpty {
                                // isLoadingOfferings false + hâlâ boş = RC offering'leri
                                // yüklenemedi (StoreKit sandbox yok vb.) — sonsuz spinner
                                // yerine geri bildirim göster (bkz. QA notu 2026-08-26,
                                // TokenStoreView'daki fallback ile aynı desen).
                                if purchases.isLoadingOfferings {
                                    ProgressView().tint(.white).frame(height: 160)
                                } else {
                                    Text("Plans aren't available right now. Please try again later.")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.white.opacity(0.6))
                                        .multilineTextAlignment(.center)
                                        .frame(height: 160)
                                        .padding(.horizontal, 24)
                                }
                            } else {
                                VStack(spacing: 10) {
                                    ForEach(packages) { pkg in
                                        planCard(pkg, isTop: pkg.id == packages.last?.id)
                                    }
                                }
                            }

                            // Token paketi ızgarası ve "— or buy tokens
                            // outright —" başlığı KALDIRILDI: bu ekran bir
                            // özelliğin kilidini açmak için ABONELİK YÜKSELTME
                            // ekranı; token satın alma alternatifi sunmak asıl
                            // eylemden uzaklaştırıyordu (bkz. kullanıcı talebi).
                            // Token satın alma yeri Store (TokenStoreView).

                            Button { restore() } label: {
                                Text("Restore Purchases")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                    }
                    .scrollIndicators(.hidden)
                    stickyFooter
                }

                if isPurchasing {
                    LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                        .overlay { ProgressView().controlSize(.large).tint(.white) }
                        .transition(.opacity)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        EventLogger.shared.log("paywall_closed", ["tier_shown": selectedTier.displayName])
                        dismiss()
                    } label: { Image(systemName: "xmark").foregroundStyle(.white) }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isPurchasing)
        .alert(item: $resultMessage) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        .task {
            EventLogger.shared.log("paywall_shown", ["default_tier": selectedTier.displayName])
            if packages.isEmpty { await purchases.loadOfferings() }
        }
    }

    // MARK: Tier seçici (Pro / Pro+ / Pro Max)

    private var tierSelector: some View {
        HStack(spacing: 2) {
            ForEach(tiers, id: \.tier) { item in
                let selected = item.tier == selectedTier
                Button {
                    selectedTier = item.tier
                    selectedPackageID = nil   // yeni tier → varsayılan (yıllık)
                    EventLogger.shared.log("paywall_tier_tab_tapped", ["tier": item.tier.displayName])
                } label: {
                    Text(item.label)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(selected ? AppColor.bg : .white.opacity(0.7))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(selected ? AppColor.amber : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(AppColor.card, in: Capsule())
    }

    // MARK: Süre kartı (weekly / monthly / yearly)

    private func planCard(_ pkg: PaywallPackage, isTop: Bool) -> some View {
        let selected = pkg.id == selectedPackage?.id
        return Button {
            selectedPackageID = pkg.id
            EventLogger.shared.log("paywall_package_selected", ["package_id": pkg.id, "tier": selectedTier.displayName, "period": pkg.periodName])
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                if isTop {
                    Text(savingsBadge(for: pkg))
                        .font(.system(size: 9, weight: .heavy)).foregroundStyle(AppColor.bg)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(AppColor.amber, in: Capsule())
                }
                HStack {
                    HStack(spacing: 7) {
                        Circle()
                            .strokeBorder(selected ? AppColor.amber : .white.opacity(0.3), lineWidth: 2)
                            .background(Circle().fill(selected ? AppColor.amber : .clear).padding(3))
                            .frame(width: 16, height: 16)
                        Text(pkg.localizedPeriodName).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    }
                    Spacer()
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text(pkg.localizedPrice).font(.system(size: 15, weight: .heavy)).foregroundStyle(AppColor.amber)
                        if let period = pkg.localizedPeriodLabel {
                            Text(period).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                HStack(spacing: 6) {
                    CoinIcon(size: 12)
                    Text("\(pkg.tokenAmount.formatted()) tokens")
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.8))
                    if let weekly = pkg.weeklyEquivalent {
                        Text("· \(weekly)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .padding(14)
            .background(selected ? AppColor.pink.opacity(0.35) : AppColor.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? AppColor.amber : .white.opacity(0.08), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private var stickyFooter: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.white.opacity(0.08))
            Button { purchaseSelected() } label: {
                Group {
                    if let pkg = selectedPackage {
                        Text("Continue — \(pkg.localizedPeriodName) \(pkg.localizedPrice)\(pkg.localizedPeriodLabel ?? "")")
                    } else {
                        Text("Continue")
                    }
                }
                .font(.system(size: 15, weight: .bold)).foregroundStyle(AppColor.bg)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(AppColor.amber, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(isPurchasing || selectedPackage == nil)
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(AppColor.bg.opacity(0.9))
    }

    // MARK: Aksiyonlar

    private func purchaseSelected() {
        guard let pkg = selectedPackage else { return }
        Task {
            isPurchasing = true
            let outcome = await purchases.purchaseDetailed(pkg)
            isPurchasing = false
            if case .success = outcome {
                await tokenStore.refresh()
                dismiss()
                return
            }
            // Başarısızlıkta ekran AÇIK kalır ki kullanıcı mesajı okuyup
            // tekrar deneyebilsin; `nil` (gerçek iptal) sessizdir.
            resultMessage = PurchaseService.userMessage(for: outcome)
        }
    }


    private func restore() {
        Task {
            isPurchasing = true
            let ok = await purchases.restore()
            if ok { await tokenStore.refresh() }
            isPurchasing = false
            if ok { dismiss() }
        }
    }
}

#Preview {
    SubscriptionPaywallView()
}
