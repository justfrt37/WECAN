//
//  OnboardingSocialProofView.swift
//  ONB2 — "Social Proof". ONB1'den (isim) sonra gelir; arka planda AYNI
//  ob1Video döngüde devam eder. İçerik öğeleri ekrana STAGGERED (sırayla,
//  hafif aşağıdan yukarı + fade) animasyonla girer.
//  Pencil "ONB1 SOCIAL PROOF" mockup'ının uygulama karşılığı.
//

import SwiftUI

struct OnboardingSocialProofView: View {
    @Environment(OnboardingStore.self) private var onboarding
    @State private var shown = false

    /// Büyük "1.000.000+" sayısının altın→mercan gradyanı (Pencil'den).
    private let numberGradient = LinearGradient(
        colors: [Color(hex: 0xFFD27A), Color(hex: 0xFF8A5C), Color(hex: 0xFF6F61)],
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        ZStack {
            LoopingVideoPlayer(resourceName: "ob1Video")
                .ignoresSafeArea()
            OBTheme.scrim
                .ignoresSafeArea()

            VStack(spacing: 14) {
                OBBrandMark(size: 22)
                    .staggered(0, shown: shown)

                Text("1,000,000+")
                    .font(.system(size: 46, weight: .heavy))
                    .foregroundStyle(numberGradient)
                    .staggered(1, shown: shown)

                Text("Dünya çapında kullanıcı")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .staggered(2, shown: shown)

                HStack(spacing: 10) {
                    statCard(icon: "star.fill", color: Color(hex: 0xFFC24B), value: "4.9", label: "Uygulama Mağazası")
                    statCard(icon: "bubble.left.fill", color: OBTheme.coral, value: "100M+", label: "Mesaj")
                    statCard(icon: "face.smiling.fill", color: Color(hex: 0x5FD08A), value: "%97", label: "Memnuniyet")
                }
                .staggered(3, shown: shown)

                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                    Text("%100 Private")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.7))
                .staggered(4, shown: shown)

                reviewCard(
                    count: "20.000+ Yorum",
                    text: "Gönderdiği fotoğraflar ve sesli mesajlar inanılmaz gerçekçi, çok etkileyici. Sanki gerçekten biriyle konuşuyorum!",
                    name: "James H."
                )
                .staggered(5, shown: shown)

                reviewCard(
                    count: nil,
                    text: "Sesli mesajları duyunca inanamadım, tam bir insan gibi. Artık her akşam konuşuyoruz.",
                    name: "Emma R."
                )
                .staggered(6, shown: shown)

                Spacer(minLength: 8)

                Button(action: advance) {
                    Text("Devam et")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(OBTheme.buttonGradient, in: RoundedRectangle(cornerRadius: 16))
                }
                .staggered(7, shown: shown)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .onAppear { shown = true }
    }

    // MARK: - Alt bileşenler

    /// Tek istatistik kartı (ikon + değer + etiket), eşit genişlik.
    private func statCard(icon: String, color: Color, value: String, label: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 21, weight: .heavy))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 6)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    /// Tek yorum kartı (yıldızlar + [sayı] + metin + avatar/isim/onay).
    private func reviewCard(count: String?, text: String, name: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                stars
                if let count {
                    Text(count)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
            }

            Text(text)
                .font(.system(size: 14))
                .italic()
                .foregroundStyle(.white.opacity(0.9))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color(hex: 0xC86DD7), Color(hex: 0xFF6F61)],
                            startPoint: .top, endPoint: .bottom
                        ))
                    Text(String(name.prefix(1)))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 30, height: 30)

                Text(name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: 0x4FA3FF))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private var stars: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { _ in
                Image(systemName: "star.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: 0xFFC24B))
            }
        }
    }

    private func advance() {
        withAnimation(.easeInOut(duration: 0.35)) {
            onboarding.step = .characterSelect
        }
    }
}

// MARK: - Staggered giriş animasyonu

private struct StaggeredEntrance: ViewModifier {
    let index: Int
    let shown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 26)
            .animation(
                .spring(response: 0.55, dampingFraction: 0.82)
                    .delay(Double(index) * 0.08),
                value: shown
            )
    }
}

private extension View {
    /// Öğeyi, `shown` true olunca `index * 0.08s` gecikmeyle aşağıdan yukarı
    /// + fade ile getirir.
    func staggered(_ index: Int, shown: Bool) -> some View {
        modifier(StaggeredEntrance(index: index, shown: shown))
    }
}
