//
//  TokenStoreView.swift
//  Token/abonelik sayfası — TokenBadge'in açtığı ve her `showPaywall = true`
//  çağrısının gösterdiği tek ekran (bkz. design doc mockup review).
//

import SwiftUI

private struct TierOption: Identifiable {
    let id: String
    let name: String
    let weeklyPrice: String
    let annualPrice: String
    let tokens: String
    let characterLine: String
    let featured: Bool
}

private let tierOptions: [TierOption] = [
    .init(id: "pro", name: "Pro", weeklyPrice: "$6.99", annualPrice: "$59.99",
          tokens: "1,000", characterLine: String(localized: "Create 1 new character per week"), featured: false),
    .init(id: "pro_plus", name: "Pro+", weeklyPrice: "$14.99", annualPrice: "$119.99",
          tokens: "2,500", characterLine: String(localized: "Create 3 new characters per week"), featured: true),
    .init(id: "max", name: "Max", weeklyPrice: "$29.99", annualPrice: "$239.99",
          tokens: "6,000", characterLine: String(localized: "Create 10 new characters per week"), featured: false),
]

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

struct TokenStoreView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isAnnual = false
    @State private var selectedTierID = "pro_plus"

    private var selectedTier: TierOption { tierOptions.first { $0.id == selectedTierID } ?? tierOptions[1] }

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

                            periodToggle

                            VStack(spacing: 10) {
                                ForEach(tierOptions) { tier in
                                    tierCard(tier)
                                }
                            }

                            Text("— or buy tokens outright, no subscription —")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.45))
                                .padding(.top, 6)

                            HStack(spacing: 8) {
                                ForEach(tokenPacks) { pack in packCard(pack) }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                    }
                    stickyFooter
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
    }

    private var periodToggle: some View {
        HStack(spacing: 2) {
            periodButton(label: String(localized: "Weekly"), isSelected: !isAnnual) { isAnnual = false }
            periodButton(label: String(localized: "Annual"), isSelected: isAnnual, sub: String(localized: "save ~83%")) { isAnnual = true }
        }
        .padding(3)
        .background(AppColor.card, in: Capsule())
    }

    private func periodButton(label: String, isSelected: Bool, sub: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(label).font(.system(size: 12, weight: .bold))
                if let sub {
                    Text(sub).font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(isSelected ? AppColor.bg : .white.opacity(0.6))
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(isSelected ? AppColor.amber : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func tierCard(_ tier: TierOption) -> some View {
        let selected = tier.id == selectedTierID
        return Button {
            selectedTierID = tier.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                if tier.featured {
                    Text("Most Popular")
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
                        Text(tier.name).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    }
                    Spacer()
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text(isAnnual ? tier.annualPrice : tier.weeklyPrice)
                            .font(.system(size: 15, weight: .heavy)).foregroundStyle(AppColor.amber)
                        Text(isAnnual ? "/yr" : "/wk")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    benefitLine("\(tier.tokens) " + String(localized: "tokens every week"))
                    benefitLine(tier.characterLine)
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
            Text("💠 \(pack.tokens)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
            Button {
                // TODO once RevenueCat is wired (see design doc "Dependencies"):
                // trigger the real StoreKit/RevenueCat purchase for this pack.
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
            Button {
                // TODO once RevenueCat is wired (see design doc "Dependencies"):
                // trigger the real StoreKit/RevenueCat subscription purchase
                // for `selectedTier`/`isAnnual`.
            } label: {
                Text("\(String(localized: "Continue")) — \(selectedTier.name) \(isAnnual ? selectedTier.annualPrice : selectedTier.weeklyPrice)\(isAnnual ? "/yr" : "/wk")")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AppColor.bg)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(AppColor.amber, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(AppColor.bg.opacity(0.9))
    }
}

#Preview {
    TokenStoreView()
}
