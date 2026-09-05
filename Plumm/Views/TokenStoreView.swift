//
//  TokenStoreView.swift
//  Coin "Mağaza" — token rozetine dokununca ana sayfada full sheet olarak
//  açılır. Coin paketleri satılır (bkz. Pencil "coinPaywall (Plumm)").
//  Kullanıcı PRO değilse üstte bir PRO yükseltme butonu gösterilir; o buton
//  abonelik paywall'unu (SubscriptionPaywallView) açar.
//
//  Gerçek satın alma: PurchaseService.tokenPackages (RevenueCat "tokens"
//  offering'inden yüklenir) + purchase(_:) — OnboardingPaywallView'ın
//  kullandığı AYNI akış (bkz. o dosyanın unlock()).
//

import SwiftUI

private enum CoinBadgeStyle { case popular, discount }

struct TokenStoreView: View {
    let tokenStore: TokenStore

    @Environment(\.dismiss) private var dismiss
    @State private var purchases = PurchaseService.shared
    @State private var purchasingId: String?
    /// Satın alma sonucu — başarı da hata da kullanıcıya GÖSTERİLİYOR.
    /// Eskiden sonuç sessizce yutuluyordu: hata durumunda ekran hiçbir şey
    /// demeden eski hâline dönüyordu (bkz. kullanıcı talebi).
    @State private var resultMessage: PurchaseAlert?

    private struct PurchaseAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let isError: Bool
    }

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Color(hex: 0x20121A), location: 0.0),
                    .init(color: Color(hex: 0x140810), location: 0.5),
                    .init(color: Color(hex: 0x0F0710), location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                if purchases.tokenPackages.isEmpty {
                    Spacer()
                    if purchases.isLoadingOfferings {
                        ProgressView().tint(.white)
                    } else {
                        Text("Coin packages aren't available right now.")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(purchases.tokenPackages) { pack in coinCard(pack) }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 30)
                    }
                    .scrollIndicators(.hidden)
                }
            }

            // Satın alma sürerken TÜM ekranı kapatan karartma + spinner.
            // Neden gerekli: satın alma App Store onayından sonra bitmiyor —
            // ardından sunucu doğrulaması geliyor (purchase-tokens: RC'yi
            // secret key ile kontrol eder, token'ı yazar, güncel bakiyeyi
            // döner) ve bu birkaç saniye sürebiliyor. O aralıkta ekran
            // dokunulabilir kalıyordu: kullanıcı token'ı henüz gelmemişken
            // eski bakiyeyi görüyor, başka bir pakete basabiliyor ya da
            // mağazayı kapatabiliyordu (bkz. kullanıcı talebi).
            //
            // `allowsHitTesting` yerine dokunuşları katmanın KENDİSİ yutuyor
            // (contentShape + üstte olması), böylece arkadaki kartların
            // basılma ihtimali kalmıyor.
            if purchasingId != nil {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { }          // dokunuşları yut
                    .overlay {
                        VStack(spacing: 14) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                            Text("Completing your purchase…")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: purchasingId)
        .alert(item: $resultMessage) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                // Başarıda mağazayı kapat (kullanıcı işini bitirdi), hatada
                // açık bırak ki tekrar deneyebilsin.
                dismissButton: .default(Text("OK")) { if !alert.isError { dismiss() } }
            )
        }
        .task {
            EventLogger.shared.log("feature_used", ["feature": "token_store_shown"])
            if purchases.tokenPackages.isEmpty { await purchases.loadOfferings() }
        }
    }

    /// Data-driven "best value" badge — the package with the lowest
    /// price-per-token, not a hardcoded guess (RevenueCat gives no
    /// "popular"/"discount" signal of its own).
    private var bestValuePackageId: String? {
        let eligible = purchases.tokenPackages.filter { $0.tokenAmount > 0 }
        let costPerToken: (PaywallPackage) -> Decimal = { $0.priceValue / Decimal($0.tokenAmount) }
        let best = eligible.min { costPerToken($0) < costPerToken($1) }
        return best?.id
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            Text("Store")
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(.white)

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)

                // "i" (info.circle) butonu kaldırıldı (bkz. kullanıcı talebi).
                // Token maliyetleri ekranına Settings'ten ulaşılıyor
                // (bkz. ProfileView > Token Costs satırı).

                Spacer()

                HStack(spacing: 6) {
                    CoinIcon(size: 16)
                    Text("\(tokenStore.balance)")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(.white.opacity(0.10), in: Capsule())
            }
        }
    }

    // MARK: Coin paketi kartı

    private func coinCard(_ pack: PaywallPackage) -> some View {
        let isBestValue = pack.id == bestValuePackageId
        let badgeStyle: CoinBadgeStyle? = isBestValue ? .discount : nil
        let isPurchasingThis = purchasingId == pack.id

        return Button {
            purchase(pack)
        } label: {
            VStack(spacing: 12) {
                // Rozet satırı — rozet yoksa da coin diskleri hizalansın diye
                // aynı yükseklikte boş yer tutar.
                Group {
                    if isBestValue {
                        Text("BEST VALUE")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .frame(height: 22)
                            .background(badgeGradient(badgeStyle), in: Capsule())
                    } else {
                        Color.clear.frame(height: 22)
                    }
                }

                StoreCoin(size: 58)

                Text("\(pack.tokenAmount)")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(.white)

                Spacer(minLength: 10)

                if isPurchasingThis {
                    ProgressView()
                        .tint(Color(hex: 0xE0561C))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    Text(pack.localizedPrice)
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(Color(hex: 0xE0561C))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(.top, 14)
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 196)
            .background(cardFill(badgeStyle), in: RoundedRectangle(cornerRadius: 22))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(cardBorder(badgeStyle), lineWidth: badgeStyle == nil ? 1 : 2)
            )
        }
        .buttonStyle(.plain)
        .disabled(purchasingId != nil)
    }

    private func purchase(_ pack: PaywallPackage) {
        guard purchasingId == nil else { return }
        Task {
            purchasingId = pack.id
            let outcome = await purchases.purchaseDetailed(pack)
            purchasingId = nil

            switch outcome {
            case .success(let granted):
                // Bakiyeyi sunucu zaten yazdı (purchase-tokens yanıtı), bu
                // yalnızca son bir doğrulama.
                await tokenStore.refresh()
                resultMessage = PurchaseAlert(
                    title: String(localized: "Purchase complete"),
                    message: granted > 0
                        ? String(localized: "\(granted.formatted()) tokens added to your balance.")
                        : String(localized: "Your purchase was successful."),
                    isError: false
                )
            case .cancelled:
                // Kullanıcının kendi kapattığı diyalog hata değil — sessiz geç.
                break
            case .failed(let reason):
                resultMessage = PurchaseAlert(
                    title: String(localized: "Purchase failed"),
                    message: reason,
                    isError: true
                )
            case .paidButNotGranted:
                // En kritik durum: para gitti, token yazılamadı. Kullanıcı
                // bunu MUTLAKA görmeli ve ne yapacağını bilmeli.
                await tokenStore.refresh()
                resultMessage = PurchaseAlert(
                    title: String(localized: "Couldn't add your tokens"),
                    message: String(localized: "Your payment went through, but we couldn't add the tokens. Check your connection and tap Restore Purchases — nothing is lost."),
                    isError: true
                )
            }
        }
    }

    private func badgeGradient(_ style: CoinBadgeStyle?) -> LinearGradient {
        switch style {
        case .discount:
            return LinearGradient(colors: [Color(hex: 0xFFD27A), Color(hex: 0xFF8A3C)],
                                  startPoint: .top, endPoint: .bottom)
        default:
            return LinearGradient(colors: [Color(hex: 0xFFAF5C), Color(hex: 0xFF6F61)],
                                  startPoint: .top, endPoint: .bottom)
        }
    }

    private func cardFill(_ style: CoinBadgeStyle?) -> Color {
        switch style {
        case .popular:  return Color(hex: 0xFF6F61).opacity(0.08)
        case .discount: return Color(hex: 0xFFC24B).opacity(0.08)
        case nil:       return Color.white.opacity(0.04)
        }
    }

    private func cardBorder(_ style: CoinBadgeStyle?) -> Color {
        switch style {
        case .popular:  return Color(hex: 0xFF6F61).opacity(0.67)
        case .discount: return Color(hex: 0xFFC24B).opacity(0.67)
        case nil:       return Color.white.opacity(0.09)
        }
    }
}

/// Mağaza'daki büyük para ikonu — Plumm kalbi (Assets "heartCoin").
/// Eskiden altın coin diski çiziliyordu.
private struct StoreCoin: View {
    var size: CGFloat = 58

    var body: some View {
        Image("heartCoin")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

#Preview {
    TokenStoreView(tokenStore: TokenStore())
}
