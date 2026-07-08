//
//  OnboardingReadyView.swift
//  ONB5 — "O bekliyor..." Onboarding'in son ekranı. Ekrana dokununca
//  onboarding tamamlanır ve uygulamaya girilir.
//  Pencil "ONB5" mockup'ının uygulama karşılığı.
//

import SwiftUI

struct OnboardingReadyView: View {
    @Environment(OnboardingStore.self) private var onboarding
    @State private var pulse = false

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
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(.white)
                    }
                    .scaleEffect(pulse ? 1.06 : 0.94)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)

                    Text("Görmek için Dokun")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white.opacity(0.95))
                        .shadow(color: .black.opacity(0.7), radius: 6, y: 2)
                }
                .padding(.bottom, 80)
            }
            .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .onAppear { pulse = true }
    }

    private func finish() {
        onboarding.complete()
    }
}
