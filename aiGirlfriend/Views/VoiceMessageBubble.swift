//
//  VoiceMessageBubble.swift
//  Sesli mesaj balonu — dalga formu + süre + oynat/durdur.
//  Metni HİÇ göstermez (voice-only tasarım kararı, bkz. design spec).
//

import SwiftUI

struct VoiceMessageBubble: View {
    let message: Message
    let isUser: Bool
    let isPlaying: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)

                HStack(spacing: 3) {
                    ForEach(0..<18, id: \.self) { i in
                        Capsule()
                            .fill(.white.opacity(isPlaying ? 0.9 : 0.6))
                            .frame(width: 2.5, height: waveformBarHeight(i))
                    }
                }

                if let duration = message.voiceDuration {
                    Text(formattedDuration(duration))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                isUser ? AppColor.pink.opacity(0.85) : AppColor.card,
                in: RoundedRectangle(cornerRadius: 18)
            )
        }
        .buttonStyle(.plain)
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
