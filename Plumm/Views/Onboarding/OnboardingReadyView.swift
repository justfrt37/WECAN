//
//  OnboardingReadyView.swift
//  ONB5 — "O bekliyor..." Onboarding'in son ekranı. Düz butona BASINCA paywall
//  (ONB6) açılır; paywall kapatılırsa seçilen kızın chat'ine girilir.
//  Pencil "ONB5" mockup'ının uygulama karşılığı.
//

import SwiftUI
import UIKit

struct OnboardingReadyView: View {
    @Environment(OnboardingStore.self) private var onboarding

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

                // Düz buton — basılı tutma yok, tek dokunuşla sonraki adım (paywall).
                // Sabit genişlik (ekran genişliği - 2×40), .infinity + dıştan padding
                // bazı cihazlarda kenara yapışık görünüyordu (bkz. kullanıcı talebi).
                Button { next() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 20, weight: .bold))
                        Text("Tap to see")
                            .font(.system(size: 20, weight: .heavy))
                    }
                    .foregroundStyle(.white)
                    .frame(height: 62)
                    .frame(width: UIScreen.main.bounds.width - 80)
                    .background(OBTheme.buttonGradient, in: RoundedRectangle(cornerRadius: 20))
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 72)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Sonraki adım: paywall (ONB6). Paywall kapatılınca seçilen kızın chat'ine
    /// girilir (bkz. OnboardingPaywallView.close) — yani araya sadece paywall
    /// giriyor, akışın kalanı aynı.
    private func next() {
        withAnimation(.easeInOut(duration: 0.3)) { onboarding.step = .paywall }
    }
}
