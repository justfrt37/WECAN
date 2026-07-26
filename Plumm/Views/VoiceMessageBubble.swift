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
    /// Gözlemlenen oynatıcı — yüksek frekanslı (20 fps) ilerleme/geçen-süre
    /// okumaları YALNIZCA bu YAPRAK alt görünümde yapılsın diye buraya taşındı.
    /// Böylece çalarken ChatView.body (tüm mesaj listesi) değil, SADECE aktif
    /// sesli mesaj balonu yeniden çizilir (bkz. ChatView ForEach, kök-neden notu).
    let voice: VoicePlayer
    /// Oynat/durdur (play tuşu ya da dururken dalga-forma dokunma).
    let onTap: () -> Void
    /// İleri/geri sarma — dalga-formu üzerinde sürükleyince oran (0...1) döner.
    var onSeek: (Double) -> Void = { _ in }

    private let barCount = 18

    var body: some View {
        // Tüm oynatıcı okumaları BURADA (yaprak body) yapılır — üst görünümlere
        // sızmaz. `isActive` önce okunur (nadir değişir); ilerleme/geçen-süre
        // (20 fps) SADECE bu balon aktifken okunur (kısa-devre), böylece pasif
        // sesli balonlar yüksek-frekanslı yeniden çizime tabi olmaz.
        let isActive = voice.speakingMessageID == message.id
        let isPlaying = isActive && voice.isPlaying
        let progress = isActive ? voice.playbackProgress : 0
        let elapsed = isActive ? voice.playbackElapsed : 0

        return HStack(spacing: 6) {
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

            Text(durationLabel(isActive: isActive, elapsed: elapsed))
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
    private func durationLabel(isActive: Bool, elapsed: Double) -> String {
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
        // Dakika sabit "0" değildi — 75 sn artık "0:75" değil "1:15" gösterir.
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
