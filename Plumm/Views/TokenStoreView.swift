//
//  TokenStoreView.swift
//  Coin "Mağaza" — token rozetine dokununca ana sayfada full sheet olarak
//  açılır. Coin paketleri satılır (bkz. Pencil "coinPaywall (Plumm)").
//  Kullanıcı PRO değilse üstte bir PRO yükseltme butonu gösterilir; o buton
//  abonelik paywall'unu (SubscriptionPaywallView) açar.
//
//  NOT: Gerçek satın alma (StoreKit/RevenueCat) henüz bağlı değil — paket
//  butonları TODO (bkz. PurchaseService iskeleti).
//

import SwiftUI

private enum CoinBadgeStyle { case popular, discount }

private struct CoinPack: Identifiable {
    let id: String
    let coins: String
    let price: String
    var badge: String? = nil
    var badgeStyle: CoinBadgeStyle? = nil
}

private let coinPacks: [CoinPack] = [
    .init(id: "100",   coins: "100",   price: "₺399,99"),
    .init(id: "250",   coins: "250",   price: "₺899,99"),
    .init(id: "500",   coins: "500",   price: "₺1.599,99"),
    .init(id: "1000",  coins: "1000",  price: "₺2.499,99", badge: "EN POPÜLER  %40", badgeStyle: .popular),
    .init(id: "5000",  coins: "5000",  price: "₺8.999,99"),
    .init(id: "10000", coins: "10000", price: "₺14.999,99", badge: "EN İNDİRİMLİ  %70", badgeStyle: .discount),
]

struct TokenStoreView: View {
    let tokenStore: TokenStore

    @Environment(\.dismiss) private var dismiss

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

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(coinPacks) { pack in coinCard(pack) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            Text("Mağaza")
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

    private func coinCard(_ pack: CoinPack) -> some View {
        Button {
            // TODO: StoreKit/RevenueCat bağlanınca bu paketin gerçek satın
            // alma akışını tetikle (bkz. PurchaseService).
        } label: {
            VStack(spacing: 12) {
                // Rozet satırı — rozet yoksa da coin diskleri hizalansın diye
                // aynı yükseklikte boş yer tutar.
                Group {
                    if let badge = pack.badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .frame(height: 22)
                            .background(badgeGradient(pack.badgeStyle), in: Capsule())
                    } else {
                        Color.clear.frame(height: 22)
                    }
                }

                StoreCoin(size: 58)

                Text(pack.coins)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(.white)

                Spacer(minLength: 10)

                Text(pack.price)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(Color(hex: 0xE0561C))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(.top, 14)
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 196)
            .background(cardFill(pack.badgeStyle), in: RoundedRectangle(cornerRadius: 22))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(cardBorder(pack.badgeStyle), lineWidth: pack.badgeStyle == nil ? 1 : 2)
            )
        }
        .buttonStyle(.plain)
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
