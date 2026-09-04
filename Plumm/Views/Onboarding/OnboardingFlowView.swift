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
                    .onAppear { logStepViewed("name", 0) }
            case .socialProof:
                OnboardingSocialProofView()
                    .transition(.opacity)
                    .onAppear { logStepViewed("social_proof", 1) }
            case .characterSelect:
                OnboardingCharacterSelectView()
                    .transition(.opacity)
                    .onAppear { logStepViewed("character_select", 2) }
            case .questions:
                OnboardingQuestionsView()
                    .transition(.opacity)
                    .onAppear { logStepViewed("questions", 3) }
            case .finalTease:
                OnboardingReadyView()
                    .transition(.opacity)
                    .onAppear { logStepViewed("final_tease", 4) }
            case .paywall:
                OnboardingPaywallView()
                    .transition(.opacity)
                    .onAppear { logStepViewed("paywall", 5) }
            }
        }
    }

    private func logStepViewed(_ step: String, _ index: Int) {
        EventLogger.shared.log("onboarding_step_viewed", ["step": step, "step_index": index])
    }
}
