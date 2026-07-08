//
//  StreakPopupView.swift
//  Haftalık (Pzt-Paz) görsel şerit — sadece KOZMETİK, gerçek hak verme
//  `claim-streak` sunucu cevabından gelir (bkz. StreakService).
//

import SwiftUI

struct StreakPopupView: View {
    let result: StreakClaimResult
    let onCollect: () -> Void

    private let dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    private func multiplierLabel(forStreak streak: Int) -> String {
        switch streak {
        case ...1: return "×1"
        case 2...4: return "×2"
        case 5...6: return "×3"
        default: return "×5"
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 20) {
                Text("Daily bonus!")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)

                if result.granted, let amount = result.amount, let streak = result.newStreak {
                    HStack(spacing: 6) {
                        ForEach(1...7, id: \.self) { day in
                            dayBox(day: day, currentStreak: streak)
                        }
                    }

                    Text("+\(amount) tokens")
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(AppColor.amber)

                    Text("\(multiplierLabel(forStreak: streak)) \(String(localized: "streak bonus"))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Button(action: onCollect) {
                    Text("Collect")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppColor.bg)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(AppColor.amber, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .background(AppColor.card, in: RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal, 32)
        }
    }

    private func dayBox(day: Int, currentStreak: Int) -> some View {
        let claimedThisWeek = day <= min(currentStreak, 7)
        return VStack(spacing: 4) {
            Text(dayLabels[day - 1])
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Circle()
                .fill(claimedThisWeek ? AppColor.amber : Color.white.opacity(0.08))
                .frame(width: 28, height: 28)
                .overlay {
                    if day == currentStreak {
                        Text(multiplierLabel(forStreak: currentStreak))
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(AppColor.bg)
                    }
                }
        }
    }
}

struct IdentifiableStreakResult: Identifiable {
    let id = UUID()
    let result: StreakClaimResult
}
