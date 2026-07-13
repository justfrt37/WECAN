//
//  OnboardingQuestionsView.swift
//  ONB4 — Seçilen karakterin videosu arka planda döngüde oynarken sırayla 2
//  soru sorulur. Her sorunun 4 saniyesi vardır (üstteki süre çubuğu dolar);
//  süre dolunca 1. şık OTOMATİK seçilir. Sayfa/video değişmez — sadece soru
//  içeriği + süre sıfırlanır. 2 soru bitince ONB5'e geçilir.
//  Pencil "ONB4" mockup'larının uygulama karşılığı.
//

import SwiftUI

private struct OBQuestion {
    let prompt: String
    let emoji: String
    let options: [String]
    /// Bu sorunun cevaplanma süresi (sn). Dolunca 1. şık otomatik seçilir.
    let duration: Double
}

struct OnboardingQuestionsView: View {
    @Environment(OnboardingStore.self) private var onboarding

    @State private var qIndex = 0
    @State private var selected: Int? = nil
    @State private var barProgress: CGFloat = 0

    private let questions: [OBQuestion] = [
        OBQuestion(
            prompt: "Ooh… cesur bir seçim. Hadi tam sana uyan birini bulalım.",
            emoji: "😉",
            options: ["Eğlenceli ve alaycı", "Yoğun kimya 🔥"],
            duration: 6
        ),
        OBQuestion(
            prompt: "Mükemmel. Peki o ortaya çıktığında nasıl hissettirmesini istersin?",
            emoji: "😳",
            options: ["Yavaş yavaş gelişen… beni bağımlısı yap", "Hızlı ve korkusuz 😏"],
            duration: 5
        ),
    ]

    private let scrim = LinearGradient(
        stops: [
            .init(color: Color(hex: 0x0E060A, alpha: 0.50), location: 0.0),
            .init(color: Color(hex: 0x0E060A, alpha: 0.15), location: 0.32),
            .init(color: Color(hex: 0x140810, alpha: 0.80), location: 0.72),
            .init(color: Color(hex: 0x0C0509, alpha: 0.95), location: 1.0),
        ],
        startPoint: .top, endPoint: .bottom
    )

    private var bgVideo: String {
        onboarding.selectedCharacter?.selectedVideo ?? "onb4Video"
    }

    private var question: OBQuestion { questions[qIndex] }

    var body: some View {
        ZStack {
            // Video ZStack'te sabit kalır — qIndex değişince YENİDEN kurulmaz,
            // böylece soru geçişinde video baştan başlamaz.
            LoopingVideoPlayer(resourceName: bgVideo)
                .ignoresSafeArea()
            scrim.ignoresSafeArea()

            VStack {
                Spacer()
                VStack(spacing: 16) {
                    questionCard
                    timeBar
                    optionRow(0)
                    optionRow(1)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 30)
            }
        }
        .task(id: qIndex) { await runQuestionTimer() }
    }

    // MARK: - Bileşenler

    private var questionCard: some View {
        VStack(spacing: 12) {
            Text(question.prompt)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            Text(question.emoji)
                .font(.system(size: 30))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 22)
        .background(Color(hex: 0x1A0E14, alpha: 0.72), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.15), lineWidth: 1))
        .id(qIndex) // metin değişiminde yeniden oluştur (yumuşak geçiş)
        .transition(.opacity)
    }

    private var timeBar: some View {
        Capsule()
            .fill(.white.opacity(0.15))
            .frame(height: 8)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(OBTheme.buttonGradient)
                    .frame(maxWidth: .infinity)
                    .scaleEffect(x: barProgress, anchor: .leading)
            }
            .clipShape(Capsule())
    }

    private func optionRow(_ i: Int) -> some View {
        let isSelected = selected == i
        let isDimmed = selected != nil && selected != i

        return Button {
            choose(i)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(isSelected ? Color.white : Color.white.opacity(0.15))
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(OBTheme.coral)
                    } else {
                        Text("\(i + 1)")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 34, height: 34)

                Text(question.options[i])
                    .font(.system(size: 15, weight: isSelected ? .bold : .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background {
                if isSelected {
                    OBTheme.buttonGradient
                } else {
                    Color.black.opacity(0.6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(.white.opacity(isSelected ? 0 : 0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .opacity(isDimmed ? 0.5 : 1)
        .disabled(selected != nil)
    }

    // MARK: - Mantık

    /// Soru başına süre çubuğu; 4 sn dolunca cevap yoksa 1. şık otomatik.
    private func runQuestionTimer() async {
        let duration = question.duration
        selected = nil
        barProgress = 0
        withAnimation(.linear(duration: duration)) { barProgress = 1 }

        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        guard !Task.isCancelled else { return }
        if selected == nil {
            choose(0) // süre doldu → ilk şık
        }
    }

    private func choose(_ i: Int) {
        guard selected == nil else { return }
        withAnimation(.easeOut(duration: 0.2)) { selected = i }

        // Cevabı kaydet.
        if onboarding.answers.count > qIndex {
            onboarding.answers[qIndex] = i
        } else {
            onboarding.answers.append(i)
        }

        // Kısa vurgudan sonra ilerle.
        Task {
            try? await Task.sleep(nanoseconds: 550_000_000)
            advance()
        }
    }

    private func advance() {
        if qIndex + 1 < questions.count {
            withAnimation(.easeInOut(duration: 0.3)) { qIndex += 1 }
        } else {
            withAnimation(.easeInOut(duration: 0.35)) { onboarding.step = .finalTease }
        }
    }
}
