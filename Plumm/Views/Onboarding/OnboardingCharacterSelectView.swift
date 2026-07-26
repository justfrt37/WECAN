//
//  OnboardingCharacterSelectView.swift
//  ONB3 — "Birini seçin". İki karakter kartı yan yana; her kartın arka planı
//  o karakterin döngü videosudur (kırmızı: ob2Video / siyah: ob2Video2).
//  Karta dokununca seçilen karakter kaydedilir ve ONB4'e (sorular) geçilir.
//  Pencil "ONB3" mockup'ının uygulama karşılığı.
//

import SwiftUI

struct OnboardingCharacterSelectView: View {
    @Environment(OnboardingStore.self) private var onboarding

    private let scrim = LinearGradient(
        stops: [
            .init(color: Color(hex: 0x0E060A, alpha: 0.80), location: 0.0),
            .init(color: Color(hex: 0x0E060A, alpha: 0.40), location: 0.28),
            .init(color: Color(hex: 0x140810, alpha: 0.70), location: 0.75),
            .init(color: Color(hex: 0x0C0509, alpha: 0.90), location: 1.0),
        ],
        startPoint: .top, endPoint: .bottom
    )

    var body: some View {
        ZStack {
            Image(bundleResource: "onb3_bg", ext: "jpg")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
            scrim.ignoresSafeArea()

            VStack(spacing: 16) {
                OBBrandMark(size: 22)
                    .padding(.top, 8)

                Text("Birini seçin")
                    .font(.system(size: 32, weight: .heavy))
                    .foregroundStyle(.white)

                HStack(spacing: 14) {
                    card(.red, emoji: "❤️", label: "Fantazi")
                    card(.second, emoji: "💑", label: "İlişki")
                }
                .frame(maxHeight: .infinity)
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private func card(_ character: OnboardingCharacter, emoji: String, label: String) -> some View {
        Button {
            select(character)
        } label: {
            ZStack(alignment: .bottomLeading) {
                LoopingVideoPlayer(resourceName: character.cardVideo)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack(spacing: 6) {
                    Text(emoji).font(.system(size: 15))
                    Text(label)
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(hex: 0x0E060A, alpha: 0.80), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 1))
                .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func select(_ character: OnboardingCharacter) {
        onboarding.selectedCharacter = character
        withAnimation(.easeInOut(duration: 0.35)) {
            onboarding.step = .questions
        }
    }
}
