//
//  SubscriptionPaywallView.swift
//  Abonelik paywall'u — RevenueCat Offerings'ten gelen abonelik paketleri
//  (UCUZDAN PAHALIYA sıralı, en pahalıda "en avantajlı" rozeti) + tek seferlik
//  token paketleri. "Upgrade" / "Go PRO" gibi her yerden `PaywallHostView` ile
//  açılır. Coin Mağazası'ndaki (TokenStoreView) "Pro" butonu da bunu açar.
//

import SwiftUI

private struct TokenPack: Identifiable {
    let id: String
    let name: String
    let price: String
    let tokens: String
}

private let tokenPacks: [TokenPack] = [
    .init(id: "small", name: "Small", price: "$5.99", tokens: "300"),
    .init(id: "medium", name: "Medium", price: "$19.99", tokens: "1,000"),
    .init(id: "large", name: "Large", price: "$59.99", tokens: "3,000"),
]

struct SubscriptionPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TokenStore.self) private var tokenStore
    @State private var purchases = PurchaseService.shared
    @State private var selectedPackageID: String?
    @State private var isPurchasing = false

    private var packages: [PaywallPackage] { purchases.packages }
    /// Seçili paket — varsayılan en pahalı (en avantajlı) paket.
    private var selectedPackage: PaywallPackage? {
        packages.first { $0.id == selectedPackageID } ?? packages.last
    }

    /// En pahalı paketin haftalık eşdeğerine göre tasarruf yüzdesi.
    private func savingsBadge(for pkg: PaywallPackage) -> String {
        let maxPerWeek = packages.compactMap(\.perWeekValue).max()
        if let mine = pkg.perWeekValue, let top = maxPerWeek, top > 0, mine < top {
            let pct = ((1 - mine / top) as NSDecimalNumber).doubleValue * 100
            return String(format: "%d%% OFF", Int(pct.rounded()))
        }
        return "Best Value"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [AppColor.bg2, AppColor.bg], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 18) {
                            Text("Get more tokens")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.top, 12)

                            if packages.isEmpty {
                                ProgressView()
                                    .tint(.white)
                                    .frame(height: 120)
                            } else {
                                VStack(spacing: 10) {
                                    // Ucuzdan pahalıya; en pahalıda tasarruf rozeti.
                                    ForEach(packages) { pkg in
                                        packageCard(pkg, isTop: pkg.id == packages.last?.id)
                                    }
                                }
                            }

                            Text("— or buy tokens outright, no subscription —")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.45))
                                .padding(.top, 6)

                            HStack(spacing: 8) {
                                ForEach(tokenPacks) { pack in packCard(pack) }
                            }

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

                // Satın alma / geri yükleme sürerken loading overlay.
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").foregroundStyle(.white)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isPurchasing)
        .task {
            if packages.isEmpty { await purchases.loadOfferings() }
        }
    }

    private func packageCard(_ pkg: PaywallPackage, isTop: Bool) -> some View {
        let selected = pkg.id == selectedPackage?.id
        return Button {
            selectedPackageID = pkg.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                if isTop {
                    Text(savingsBadge(for: pkg))
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(AppColor.bg)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(AppColor.amber, in: Capsule())
                }
                HStack {
                    HStack(spacing: 7) {
                        Circle()
                            .strokeBorder(selected ? AppColor.amber : .white.opacity(0.3), lineWidth: 2)
                            .background(Circle().fill(selected ? AppColor.amber : .clear).padding(3))
                            .frame(width: 16, height: 16)
                        Text(pkg.periodName).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Spacer()
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text(pkg.localizedPrice)
                            .font(.system(size: 15, weight: .heavy)).foregroundStyle(AppColor.amber)
                        if let period = pkg.periodLabel {
                            Text(period)
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                if let weekly = pkg.weeklyEquivalent {
                    benefitLine(weekly)
                }
            }
            .padding(14)
            .background(selected ? AppColor.pink.opacity(0.35) : AppColor.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? AppColor.amber : .white.opacity(0.08), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private func benefitLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text("✓").font(.system(size: 11, weight: .heavy)).foregroundStyle(AppColor.amber)
            Text(text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.8))
        }
    }

    private func packCard(_ pack: TokenPack) -> some View {
        VStack(spacing: 6) {
            Text(pack.name).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            Text(pack.price).font(.system(size: 14, weight: .heavy)).foregroundStyle(AppColor.amber)
            HStack(spacing: 4) {
                CoinIcon(size: 11)
                Text("\(pack.tokens)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
            }
            Button {
                buyTokenPack(pack)
            } label: {
                Text("Buy")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(AppColor.pink, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(AppColor.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private var stickyFooter: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.white.opacity(0.08))
            Button { purchaseSelected() } label: {
                Group {
                    if isPurchasing {
                        ProgressView().tint(AppColor.bg)
                    } else if let pkg = selectedPackage {
                        Text("Continue — \(pkg.periodName) \(pkg.localizedPrice)\(pkg.periodLabel ?? "")")
                    } else {
                        Text("Continue")
                    }
                }
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(AppColor.bg)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(AppColor.amber, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(isPurchasing || selectedPackage == nil)
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(AppColor.bg.opacity(0.9))
    }

    // MARK: Satın alma aksiyonları

    private func purchaseSelected() {
        guard let pkg = selectedPackage else { return }
        Task {
            isPurchasing = true
            let ok = await purchases.purchase(pkg)
            if ok { await tokenStore.refresh() }   // sunucu verdiği token'ları çek
            isPurchasing = false
            if ok { dismiss() }
        }
    }

    /// Token paketi id'si offering'te varsa satın alır (consumable'lar ayrı bir
    /// offering'te tanımlıysa dashboard'da eşleştirilmeli).
    private func buyTokenPack(_ pack: TokenPack) {
        guard let match = packages.first(where: { $0.id == pack.id }) else { return }
        Task {
            isPurchasing = true
            _ = await purchases.purchase(match)
            isPurchasing = false
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
