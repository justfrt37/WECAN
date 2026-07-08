//
//  OnboardingNameView.swift
//  ONB1 — "Adınız Nedir?" isim girişi.
//  Arka planda ob1Video sonsuz döngüde oynar, üstüne karartma biner.
//  Pencil "ONB1" mockup'ının uygulama karşılığı.
//

import SwiftUI

struct OnboardingNameView: View {
    @Environment(OnboardingStore.self) private var onboarding
    @FocusState private var nameFocused: Bool

    private var trimmedName: String {
        onboarding.userName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        @Bindable var onboarding = onboarding

        ZStack {
            LoopingVideoPlayer(resourceName: "ob1Video")
                .ignoresSafeArea()

            OBTheme.scrim
                .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 22) {
                    OBBrandMark(size: 22)
                        .padding(.top, 4)

                    Text("Adınız Nedir?")
                        .font(.system(size: 32, weight: .heavy))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    TextField(
                        "",
                        text: $onboarding.userName,
                        prompt: Text("Adını gir").foregroundStyle(.white.opacity(0.5))
                    )
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .tint(OBTheme.coral)
                    .focused($nameFocused)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(advance)
                    .padding(.horizontal, 20)
                    .frame(height: 54)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(.white.opacity(0.20), lineWidth: 1)
                    )

                    HStack {
                        Spacer()
                        Button(action: skip) {
                            Text("Skip")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                .padding(.top, 20)

                Spacer(minLength: 24)

                Button(action: advance) {
                    Text("Devam et")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(OBTheme.buttonGradient, in: RoundedRectangle(cornerRadius: 16))
                }
                .disabled(trimmedName.isEmpty)
                .opacity(trimmedName.isEmpty ? 0.5 : 1)
                .animation(.easeInOut(duration: 0.2), value: trimmedName.isEmpty)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .contentShape(Rectangle())
        .onTapGesture { nameFocused = false }
    }

    /// İsmi kaydedip sonraki adıma geç.
    private func advance() {
        guard !trimmedName.isEmpty else { return }
        onboarding.userName = trimmedName
        nameFocused = false
        goNext()
    }

    /// İsmi atla — boş bırakıp sonraki adıma geç.
    private func skip() {
        nameFocused = false
        goNext()
    }

    private func goNext() {
        withAnimation(.easeInOut(duration: 0.35)) {
            onboarding.step = .socialProof
        }
    }
}
