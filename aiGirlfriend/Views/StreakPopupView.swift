//
//  StreakPopupView.swift
//  "Günlük Ödüller" popup'ı — home (Keşfet) üstünde modal olarak açılır
//  (bkz. MainTabView .task → StreakService.claim). SADECE KOZMETİK: gerçek
//  hak verme + streak/sıfırlama mantığı TAMAMEN sunucuda (bkz. claim-streak:
//  yerel gün tam +1 ilerlemişse streak devam eder, aksi halde 1'e sıfırlanır).
//
//  Tasarım: AIGUI .pen "Günlük Ödüller (Home Popup)".
//

import SwiftUI

struct StreakPopupView: View {
    let result: StreakClaimResult
    let onCollect: () -> Void

    private let coral = Color(hex: 0xFF6F61)
    private let gold = Color(hex: 0xFFC24B)
    private let redHeart = Color(hex: 0xFF2D55)

    /// Sunucu çarpanıyla (bkz. claim-streak multiplierForStreak) birebir aynı:
    /// Gün 1 = 10, Gün 2-4 = 20, Gün 5-6 = 30, Gün 7 = 50.
    private func amount(forDay day: Int) -> Int {
        let mult: Int
        switch day {
        case ...1: mult = 1
        case 2...4: mult = 2
        case 5...6: mult = 3
        default:    mult = 5
        }
        return 10 * mult
    }

    /// 7 günlük döngüde bugünün günü (streak 8 → yeni haftanın 1. günü).
    private var cycleDay: Int {
        let s = max(1, result.newStreak ?? 1)
        return ((s - 1) % 7) + 1
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.68).ignoresSafeArea()

            VStack(spacing: 0) {
                closeBar
                header
                daysRow
                claimButton
            }
            .padding(.bottom, 22)
            .background(
                LinearGradient(colors: [Color(hex: 0x1C0E17), Color(hex: 0x2A1320), Color(hex: 0x1C0E17)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 26, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.6), radius: 30, y: 16)
            .padding(.horizontal, 26)
        }
    }

    // MARK: Parçalar

    private var closeBar: some View {
        HStack {
            Spacer()
            Button(action: onCollect) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.08), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 14)
        .padding(.horizontal, 16)
    }

    private var header: some View {
        Text("Günlük Ödüller")
            .font(.system(size: 24, weight: .heavy))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 2)
    }

    /// 7 gün tek satırda, yatay kaydırılabilir (bkz. tasarım).
    private var daysRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(1...7, id: \.self) { day in
                    dayCell(day)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 14)
    }

    private func dayCell(_ day: Int) -> some View {
        let isToday = day == cycleDay
        let isClaimed = day < cycleDay
        let amt = amount(forDay: day)

        let bg: Color = isToday ? coral.opacity(0.14) : .white.opacity(isClaimed ? 0.05 : 0.03)
        let border: Color = isToday ? coral : .white.opacity(0.09)
        let labelColor: Color = isToday ? .white : .white.opacity(isClaimed ? 0.55 : 0.4)

        return VStack(spacing: 6) {
            Text("Gün \(day)")
                .font(.system(size: 11, weight: isToday ? .heavy : .bold))
                .foregroundStyle(labelColor)
            Group {
                if isClaimed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(coral)
                } else {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(isToday ? coral : coral.opacity(0.35))
                }
            }
            .font(.system(size: isToday ? 22 : 20))
            Text("+\(amt)")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(labelColor)
        }
        .frame(width: 82)
        .padding(.vertical, 14)
        .background(bg, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(border, lineWidth: isToday ? 2 : 1))
    }

    private var claimButton: some View {
        Button(action: onCollect) {
            HStack(spacing: 8) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(redHeart)
                Text("Ödülü Al  ·  +\(result.amount ?? amount(forDay: cycleDay))")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color(hex: 0x1A0B14))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(colors: [coral, gold], startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 16)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }
}

struct IdentifiableStreakResult: Identifiable {
    let id = UUID()
    let result: StreakClaimResult
}
