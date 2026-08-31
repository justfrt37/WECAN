//
//  RelationshipLevelsView.swift
//  İlişki Seviyeleri — profil sayfasındaki seviye çemberine dokununca açılan
//  liste. 10 seviyeli ilişki ilerlemesini gösterir; kullanıcının şu anki
//  seviyesi vurgulanır, geçmiş seviyeler mercan halkalı, gelecek seviyeler
//  soluk, 10. seviye (Ruh İkizleri) altın renkli.
//  Tasarım: AIGUI .pen "İlişki Seviyeleri (Plumm)" (Ej48q).
//

import SwiftUI

private struct RelationshipLevel: Identifiable {
    let id: Int          // 1...10
    let title: String
    let blurb: String
}

private let relationshipLevels: [RelationshipLevel] = [
    .init(id: 1,  title: String(localized: "Strangers"),        blurb: String(localized: "You just met, getting to know each other.")),
    .init(id: 2,  title: String(localized: "Acquaintances"),    blurb: String(localized: "You've started getting to know each other.")),
    .init(id: 3,  title: String(localized: "Friends"),          blurb: String(localized: "There's a genuine friendship between you.")),
    .init(id: 4,  title: String(localized: "Close Friends"),    blurb: String(localized: "You trust each other and share most things.")),
    .init(id: 5,  title: String(localized: "Flirting"),         blurb: String(localized: "Sparks have started flying between you.")),
    .init(id: 6,  title: String(localized: "Partners"),         blurb: String(localized: "You're officially together now.")),
    .init(id: 7,  title: String(localized: "Lovers"),           blurb: String(localized: "You're passionately bound to each other.")),
    .init(id: 8,  title: String(localized: "Committed"),        blurb: String(localized: "You dream of the future together.")),
    .init(id: 9,  title: String(localized: "Engaged"),          blurb: String(localized: "The proposal is done, the big day approaches.")),
    .init(id: 10, title: String(localized: "Soulmates"),        blurb: String(localized: "You complete each other, the highest level.")),
]

struct RelationshipLevelsView: View {
    let characterId: UUID
    /// Token boost'lar sonrası anında güncellenmesi için `@State` — sunucu
    /// tek doğru kaynak (bkz. level-boost edge function), başarı sonrası
    /// `onBoosted` çağıranın (CharacterProfileView) kendi kalıcı önbelleklerini
    /// (levelCache/LocalConversationStore) güncellemesi için de gerekli.
    @State private var currentLevel: Int
    @State private var tokenBalance: Int
    @State private var isBoosting = false
    let onBoosted: (_ newLevel: Int, _ newBalance: Int) -> Void
    let onInsufficientTokens: () -> Void
    @Environment(\.dismiss) private var dismiss
    private let service = ChatService()

    init(characterId: UUID, currentLevel: Int, tokenBalance: Int,
         onBoosted: @escaping (_ newLevel: Int, _ newBalance: Int) -> Void,
         onInsufficientTokens: @escaping () -> Void) {
        self.characterId = characterId
        self._currentLevel = State(initialValue: currentLevel)
        self._tokenBalance = State(initialValue: tokenBalance)
        self.onBoosted = onBoosted
        self.onInsufficientTokens = onInsufficientTokens
    }

    // Pencil tasarımından birebir tonlar
    private let coral = Color(hex: 0xFF6F61)
    private let gold = Color(hex: 0xFFC24B)
    private let ringBG = Color(hex: 0x1A0B14)

    private static let maxLevel = 10
    private static func boostCost(forTargetLevel level: Int) -> Int {
        if level <= 5 { return 50 }
        if level <= 8 { return 100 }
        return 200
    }

    private func boost() {
        guard !isBoosting, currentLevel < Self.maxLevel else { return }
        let cost = Self.boostCost(forTargetLevel: currentLevel + 1)
        guard tokenBalance >= cost else {
            onInsufficientTokens()
            return
        }
        isBoosting = true
        Task {
            if let result = await service.boostLevel(characterId: characterId) {
                currentLevel = result.level
                tokenBalance = result.tokenBalance
                onBoosted(result.level, result.tokenBalance)
            } else {
                // Ağ hatası/yarışta bakiye değişmiş olabilir — güvenli taraf:
                // yetersiz bakiye akışını aç (kullanıcı en kötü paywall/coin
                // mağazasını gereksiz görür, sessizce hiçbir şey olmamasından iyi).
                onInsufficientTokens()
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
                        ForEach(relationshipLevels) { level in
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

    private func levelRow(_ level: RelationshipLevel) -> some View {
        let isCurrent = level.id == currentLevel
        let isPast = level.id < currentLevel
        let isTop = level.id == 10

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

        return HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(ringBG)
                    .overlay(Circle().strokeBorder(ringStroke, lineWidth: ringWidth))
                Text("\(level.id)")
                    .font(.system(size: level.id == 10 ? 16 : 17, weight: .heavy))
                    .foregroundStyle(numberColor)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(level.title)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(titleColor)
                Text(isCurrent ? "\(level.blurb) " + String(localized: "(your current level)") : level.blurb)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                    .foregroundStyle(blurbColor)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)

            // Token boost — sadece BİR SONRAKİ seviyenin kartında (bkz.
            // level-boost edge function, her çağrı tam 1 seviye atlatır).
            if level.id == currentLevel + 1 {
                boostButton(targetLevel: level.id)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(cardStroke, lineWidth: cardStrokeWidth))
    }

    private func boostButton(targetLevel: Int) -> some View {
        let cost = Self.boostCost(forTargetLevel: targetLevel)
        return Button { boost() } label: {
            if isBoosting {
                ProgressView().tint(.white).frame(width: 60, height: 30)
            } else {
                VStack(spacing: 1) {
                    Text("Boost").font(.system(size: 11, weight: .bold))
                    Text("\(cost) 🪙").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(LinearGradient(colors: [coral, gold], startPoint: .leading, endPoint: .trailing), in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .disabled(isBoosting)
    }
}

#Preview {
    RelationshipLevelsView(characterId: UUID(), currentLevel: 3, tokenBalance: 100, onBoosted: { _, _ in }, onInsufficientTokens: {})
}
