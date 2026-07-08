//
//  OnboardingFlowView.swift
//  Onboarding akışının kök container'ı — mevcut adıma göre ekranı seçer.
//  Uygulama, auth + karakter kataloğu yüklendikten sonra `isCompleted` false
//  ise bu view'ı gösterir (bkz. aiGirlfriendApp).
//
//  Şu an implement edilenler: ONB1 (isim). ONB2 (social proof), ONB3
//  (karakter seçimi + sorular) ve sonrası "yakında" placeholder'ı ile
//  temsil edilir; akış oradan uygulamaya girer.
//

import SwiftUI

struct OnboardingFlowView: View {
    @Environment(OnboardingStore.self) private var onboarding

    var body: some View {
        ZStack {
            OBTheme.bg.ignoresSafeArea()

            switch onboarding.step {
            case .name:
                OnboardingNameView()
                    .transition(.opacity)
            case .socialProof:
                OnboardingSocialProofView()
                    .transition(.opacity)
            case .characterSelect:
                OnboardingCharacterSelectView()
                    .transition(.opacity)
            case .questions:
                OnboardingQuestionsView()
                    .transition(.opacity)
            case .finalTease:
                OnboardingReadyView()
                    .transition(.opacity)
            }
        }
    }
}

/// Henüz yapılmamış adımlar için geçici ekran. ONB1'den sonra akışın
/// devam ettiğini gösterir ve uygulamaya girmek için bir çıkış sağlar.
private struct OnboardingComingSoonView: View {
    @Environment(OnboardingStore.self) private var onboarding

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            OBBrandMark(size: 26)

            Text(greeting)
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text("Sıradaki adımlar (social proof, karakter seçimi) yakında.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button {
                onboarding.complete()
            } label: {
                Text("Uygulamaya gir")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(OBTheme.buttonGradient, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }

    private var greeting: String {
        let name = onboarding.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Hoş geldin!" : "Hoş geldin, \(name)!"
    }
}
