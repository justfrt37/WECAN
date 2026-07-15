//
//  VoiceMessageBubble.swift
//  Sesli mesaj balonu — dalga formu + süre + oynat/durdur.
//  Metni HİÇ göstermez (voice-only tasarım kararı, bkz. design spec).
//  Çalarken WhatsApp gibi: dalga-formu ilerleme oranına kadar dolar, süre
//  yazısı geçen süreyi gösterir ve dalga-formu üzerinde sürükleyerek ileri/geri
//  sarılabilir (bkz. onSeek / VoicePlayer.seek).
//

import SwiftUI

struct VoiceMessageBubble: View {
    let message: Message
    let isUser: Bool
    /// GERÇEKTEN çalıyor mu — play/pause ikonu buna bakar.
    let isPlaying: Bool
    /// AKTİF mi (çalıyor VEYA duraklatılmış) — ilerleme, sarma ve süre buna bakar,
    /// böylece duraklatılmışken de dalga dolu görünür ve sarma yapılabilir.
    var isActive: Bool = false
    /// Oynatma ilerlemesi (0...1) — sadece bu balon aktifken anlamlı.
    var progress: Double = 0
    /// Geçen süre (saniye) — çalarken süre yazısı bunu gösterir.
    var elapsed: Double = 0
    /// Oynat/durdur (play tuşu ya da dururken dalga-forma dokunma).
    let onTap: () -> Void
    /// İleri/geri sarma — dalga-formu üzerinde sürükleyince oran (0...1) döner.
    var onSeek: (Double) -> Void = { _ in }

    private let barCount = 18

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onTap) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            // Dalga-formu = sürüklenebilir scrubber. Çalarken sürükleme sarar,
            // dururken tek dokunuş oynatır.
            GeometryReader { geo in
                HStack(spacing: 3) {
                    ForEach(0..<barCount, id: \.self) { i in
                        let played = isActive && Double(i) / Double(barCount) <= progress
                        Capsule()
                            .fill(.white.opacity(played ? 1.0 : (isActive ? 0.35 : 0.6)))
                            .frame(width: 2.5, height: waveformBarHeight(i))
                    }
                }
                // Sola yasla → dalga-formu play tuşuna yakın dursun (bkz. kullanıcı
                // talebi: aralarında çok boşluk vardı).
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // Sarma AKTİFKEN (çalıyor VEYA duraklatılmış) yapılabilir —
                // duraklatılmışken de ileri/geri sarılır (bkz. kullanıcı talebi).
                // Aktif değilken jest kapalı ki kaydırmayı (ScrollView) engellemesin.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in onSeek(fraction(v.location.x, width: geo.size.width)) }
                        .onEnded { v in onSeek(fraction(v.location.x, width: geo.size.width)) },
                    including: isActive ? .all : .none
                )
            }
            .frame(width: 108, height: 24)

            Text(durationLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            isUser ? AppColor.pink.opacity(0.85) : AppColor.card,
            in: RoundedRectangle(cornerRadius: 18)
        )
    }

    private func fraction(_ x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(1, max(0, Double(x / width)))
    }

    /// Çalarken geçen süre, dururken toplam süre — ikisi de yoksa gizli.
    private var durationLabel: String {
        if isActive { return formattedDuration(elapsed) }   // çalıyor veya duraklatılmış
        if let duration = message.voiceDuration { return formattedDuration(duration) }
        return ""
    }

    /// Gerçek genlik verisi yok (mp3'ü ayrıştırmıyoruz) — sabit ama düzensiz
    /// bir dalga-formu deseni, her zaman aynı görünüyor, yalnızca dekoratif.
    private func waveformBarHeight(_ index: Int) -> CGFloat {
        let pattern: [CGFloat] = [8, 14, 10, 18, 12, 16, 9, 20, 11, 15, 8, 17, 13, 19, 10, 14, 9, 16]
        return pattern[index % pattern.count]
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "0:%02d", total)
    }
}
