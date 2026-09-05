//
//  RelationshipLevelsView.swift
//  İlişki Seviyeleri — profil sayfasındaki seviye çemberine / "İlerlemeyi Gör"
//  butonuna dokununca açılan liste. 10 seviyeli ilişki ilerlemesini gösterir;
//  kullanıcının şu anki seviyesi vurgulanır, geçmiş seviyeler mercan halkalı,
//  gelecek seviyeler soluk, 10. seviye altın renkli.
//
//  Seviye ADLARI artık karakterin rolüne göre (bkz. Relationship.stageName) —
//  eskiden burada sabit, romantik-statü ağırlıklı bir liste ("Lovers",
//  "Engaged"...) vardı; kaldırıldı (kullanıcı talebi 2026-09-02). Tek doğru
//  kaynak Relationship.stageName + Relationship.stageBlurb.
//

import SwiftUI

struct RelationshipLevelsView: View {
    let characterId: UUID
    /// Seviye adlarını doğru role göre çözmek için (bkz. Relationship.stageName).
    let role: String
    /// Token boost'lar sonrası anında güncellenmesi için `@State` — sunucu
    /// tek doğru kaynak (bkz. level-boost edge function), başarı sonrası
    /// `onBoosted` çağıranın (CharacterProfileView) kendi kalıcı önbelleklerini
    /// (levelCache/LocalConversationStore) güncellemesi için de gerekli.
    @State private var currentLevel: Int
    @State private var tokenBalance: Int
    @State private var isBoosting = false
    @State private var boostError: String?
    let onBoosted: (_ newLevel: Int, _ newBalance: Int) -> Void
    let onInsufficientTokens: () -> Void
    /// No active subscription → boosting isn't available, open the paywall.
    let onNeedsSubscription: () -> Void
    @Environment(\.dismiss) private var dismiss
    private let service = ChatService()

    init(characterId: UUID, role: String, currentLevel: Int, tokenBalance: Int,
         onBoosted: @escaping (_ newLevel: Int, _ newBalance: Int) -> Void,
         onInsufficientTokens: @escaping () -> Void,
         onNeedsSubscription: @escaping () -> Void) {
        self.characterId = characterId
        self.role = role
        self._currentLevel = State(initialValue: currentLevel)
        self._tokenBalance = State(initialValue: tokenBalance)
        self.onBoosted = onBoosted
        self.onInsufficientTokens = onInsufficientTokens
        self.onNeedsSubscription = onNeedsSubscription
    }

    /// max: boost bedava. pro / pro_plus: token öder. none: paywall.
    private var tier: SubscriptionTier { PurchaseService.shared.tier }

    // Pencil tasarımından birebir tonlar
    private let coral = Color(hex: 0xFF6F61)
    private let gold = Color(hex: 0xFFC24B)
    private let ringBG = Color(hex: 0x1A0B14)

    private static let maxLevel = 10

    private func boost() {
        guard !isBoosting, currentLevel < Self.maxLevel else { return }

        // Abonelik yoksa boost yok — paywall.
        guard tier != .none else {
            onNeedsSubscription()
            return
        }
        // max bedava; pro / pro_plus token öder — bakiye yetmiyorsa istek atma.
        if tier != .max {
            let cost = TokenCosts.levelBoost(toLevel: currentLevel + 1)
            guard tokenBalance >= cost else {
                onInsufficientTokens()
                return
            }
        }

        isBoosting = true
        Task {
            switch await service.boostLevel(characterId: characterId) {
            case .success(let result):
                currentLevel = result.level
                tokenBalance = result.tokenBalance
                EventLogger.shared.log("feature_used", ["feature": "level_boost", "new_level": result.level])
                onBoosted(result.level, result.tokenBalance)
            case .insufficientTokens:
                onInsufficientTokens()
            case .needsSubscription:
                onNeedsSubscription()
            case .alreadyMaxLevel:
                currentLevel = Self.maxLevel
            case .failed:
                boostError = String(localized: "Couldn't boost right now. Check your connection and try again.")
            }
            isBoosting = false
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x140810), Color(hex: 0x24101C), Color(hex: 0x140810)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(1...Self.maxLevel, id: \.self) { level in
                            levelRow(level)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
        }
        .preferredColorScheme(.dark)
        .alert(String(localized: "Boost failed"), isPresented: Binding(
            get: { boostError != nil },
            set: { if !$0 { boostError = nil } }
        )) {
            Button("OK", role: .cancel) { boostError = nil }
        } message: {
            Text(boostError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Relationship Levels")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(.white)
                Text("As you chat your level rises and your bond deepens.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                if currentLevel < Self.maxLevel {
                    Text("Chat to grow closer over time — or spend tokens to jump ahead now.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.1), in: Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func levelRow(_ level: Int) -> some View {
        let isCurrent = level == currentLevel
        let isPast = level < currentLevel
        let isTop = level == Self.maxLevel

        // Halka rengi
        let ringStroke: Color = {
            if isTop { return gold }
            if isCurrent || isPast { return coral }
            return .white.opacity(0.18)
        }()
        let ringWidth: CGFloat = isCurrent ? 4 : 3

        // Kart arka planı + kenarlık
        let cardFill: Color = {
            if isTop { return gold.opacity(0.08) }
            if isCurrent { return coral.opacity(0.08) }
            return .white.opacity(0.05)
        }()
        let cardStroke: Color = {
            if isTop { return gold.opacity(0.5) }
            if isCurrent { return coral }
            return .white.opacity(0.09)
        }()
        let cardStrokeWidth: CGFloat = isCurrent ? 2 : (isTop ? 1.5 : 1)

        // Yazı renkleri
        let dimmed = !isCurrent && !isPast && !isTop
        let numberColor: Color = dimmed ? .white.opacity(0.5) : .white
        let titleColor: Color = dimmed ? .white.opacity(0.8) : .white
        let blurbColor: Color = {
            if isCurrent { return Color(hex: 0xFFD9D2) }
            if isTop { return Color(hex: 0xFFE9C2) }
            return .white.opacity(0.55)
        }()

        let title = Relationship.stageName(level, role: role)
        let blurb = Relationship.stageBlurb(level)

        return HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(ringBG)
                    .overlay(Circle().strokeBorder(ringStroke, lineWidth: ringWidth))
                Text("\(level)")
                    .font(.system(size: level == 10 ? 16 : 17, weight: .heavy))
                    .foregroundStyle(numberColor)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(titleColor)
                Text(isCurrent ? blurb + " " + String(localized: "(your current level)") : blurb)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                    .foregroundStyle(blurbColor)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)

            // Token boost — sadece BİR SONRAKİ seviyenin kartında (bkz.
            // level-boost edge function, her çağrı tam 1 seviye atlatır).
            if level == currentLevel + 1 {
                boostButton(targetLevel: level)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(cardStroke, lineWidth: cardStrokeWidth))
    }

    private func boostButton(targetLevel: Int) -> some View {
        // Fiyat SADECE pro / pro_plus için gösterilir (bkz. kullanıcı talebi):
        // max'te boost bedava, abonelik yoksa dokununca paywall açılır.
        let showsCost = tier == .pro || tier == .proPlus
        return Button { boost() } label: {
            if isBoosting {
                ProgressView().tint(.white).frame(width: 60, height: 30)
            } else {
                VStack(spacing: 1) {
                    Text("Boost").font(.system(size: 12, weight: .bold))
                    if showsCost {
                        HStack(spacing: 3) {
                            Text("\(TokenCosts.levelBoost(toLevel: targetLevel))")
                                .font(.system(size: 10, weight: .semibold))
                            CoinIcon(size: 10)
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, showsCost ? 6 : 7)
                .background(LinearGradient(colors: [coral, gold], startPoint: .leading, endPoint: .trailing), in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .disabled(isBoosting)
    }
}

#Preview {
    RelationshipLevelsView(characterId: UUID(), role: "flirty", currentLevel: 3, tokenBalance: 100, onBoosted: { _, _ in }, onInsufficientTokens: {}, onNeedsSubscription: {})
}
