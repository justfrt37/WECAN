//
//  OnboardingFlowView.swift
//  Onboarding akışının kök container'ı — mevcut adıma göre ekranı seçer.
//  Uygulama, auth + karakter kataloğu yüklendikten sonra `isCompleted` false
//  ise bu view'ı gösterir (bkz. PlummApp).
//
//  Adımlar (bkz. OnboardingStore.Step): isim → social proof → karakter seçimi
//  → sorular → final tease → paywall; sonrasında akış uygulamaya girer.
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
            case .paywall:
                OnboardingPaywallView()
                    .transition(.opacity)
            }
        }
    }
}
