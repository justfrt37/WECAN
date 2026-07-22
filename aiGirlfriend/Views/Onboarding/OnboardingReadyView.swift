//
//  OnboardingReadyView.swift
//  ONB5 — "O bekliyor..." Onboarding'in son ekranı. Butona BASILI TUTUNCA
//  (progress ring dolar) seçilen kızın chat'ine yumuşak geçişle girilir.
//  Pencil "ONB5" mockup'ının uygulama karşılığı.
//

import SwiftUI

struct OnboardingReadyView: View {
    @Environment(OnboardingStore.self) private var onboarding
    @State private var holdProgress: CGFloat = 0
    @State private var isHolding = false
    private let holdDuration: Double = 0.6

    var body: some View {
        ZStack {
            Image(bundleResource: "onb5_bg", ext: "png")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.35), location: 0.0),
                    .init(color: .black.opacity(0.07), location: 0.4),
                    .init(color: .black.opacity(0.45), location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack {
                Text("O bekliyor...")
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 8, y: 2)
                    .padding(.top, 24)

                Spacer()

                VStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .fill(Color(hex: 0x160A12, alpha: 0.90))
                            .frame(width: 118, height: 118)
                            .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1.5))
                            .shadow(color: .black.opacity(0.5), radius: 22, y: 6)

                        // Basılı tutarken dolan ilerleme halkası.
                        Circle()
                            .trim(from: 0, to: holdProgress)
                            .stroke(
                                LinearGradient(colors: [Color(hex: 0xFFAF5C), Color(hex: 0xFF6F61)],
                                               startPoint: .top, endPoint: .bottom),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round)
                            )
                            .frame(width: 118, height: 118)
                            .rotationEffect(.degrees(-90))

                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(.white)
                    }
                    .scaleEffect(isHolding ? 1.12 : 1.0)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isHolding)

                    Text("Görmek için Basılı Tut")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white.opacity(0.95))
                        .shadow(color: .black.opacity(0.7), radius: 6, y: 2)
                }
                .padding(.bottom, 80)
            }
            .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: holdDuration, maximumDistance: 80) { pressing in
            isHolding = pressing
            if pressing {
                withAnimation(.linear(duration: holdDuration)) { holdProgress = 1 }
            } else {
                // Erken bırakıldı — halkayı geri sar.
                withAnimation(.easeOut(duration: 0.25)) { holdProgress = 0 }
            }
        } perform: {
            finish()
        }
    }

    private func finish() {
        // PAYWALL YOK. Karakter seçiliyse (kırmızı→Scarlet / diğeri→Maya) chat'i
        // MainTabView açar ve onboarding TAM DA CHAT GÖRÜNÜNCE complete olur
        // (bkz. MainTabView.openPendingOnboardingChat). Seçim yoksa direkt bitir.
        if let name = onboarding.selectedCharacter?.chatCharacterName {
            onboarding.pendingChatCharacterName = name
        } else {
            onboarding.complete()
        }
    }
}
