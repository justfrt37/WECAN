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
                    .onAppear { logStepViewed("name") }
            case .socialProof:
                OnboardingSocialProofView()
                    .transition(.opacity)
                    .onAppear { logStepViewed("social_proof") }
            case .characterSelect:
                OnboardingCharacterSelectView()
                    .transition(.opacity)
                    .onAppear { logStepViewed("character_select") }
            case .questions:
                OnboardingQuestionsView()
                    .transition(.opacity)
                    .onAppear { logStepViewed("questions") }
            case .finalTease:
                OnboardingReadyView()
                    .transition(.opacity)
                    .onAppear { logStepViewed("final_tease") }
            case .paywall:
                OnboardingPaywallView()
                    .transition(.opacity)
                    .onAppear { logStepViewed("paywall") }
            }
        }
    }

    /// Adımın SIRASI değil ADI loglanıyor (bkz. kullanıcı talebi). Sayısal
    /// indeks, araya yeni bir adım eklendiğinde geçmiş veriyi sessizce
    /// kaydırıyordu: dünün "3"ü ile bugünün "3"ü farklı ekranlar oluyor ve
    /// funnel geriye dönük yanlış okunuyordu. Ad sabit kalır.
    private func logStepViewed(_ step: String) {
        EventLogger.shared.log("onboarding_step_viewed", ["step": step])
    }
}
