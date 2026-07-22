//
//  TokenBadge.swift
//  Her ekranda görünmesi gereken kalıcı token rozeti — sayı + "+" kutusu,
//  hepsi TEK dokunma hedefi (bkz. design doc: "Not two separate tap targets").
//  `tokenStore.lastDelta` her değiştiğinde küçük bir "+1000"/"-25" animasyonu
//  gösterir (bkz. TokenStore.setBalance) — harcama/kazanma her zaman görünür olsun diye.
//

import SwiftUI

/// Uygulamanın para birimi ikonu — Plumm kalbi (bkz. Assets "heartCoin",
/// heart.pdf vektörü). Eskiden altın coin çiziliyordu.
struct CoinIcon: View {
    var size: CGFloat = 16
    var body: some View {
        Image("heartCoin")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

struct TokenBadge: View {
    let tokenStore: TokenStore
    let onTap: () -> Void

    @State private var floatingDelta: Int?
    @State private var floatingOffsetY: CGFloat = 0
    @State private var floatingOffsetX: CGFloat = 0
    @State private var floatingOpacity: Double = 0

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                CoinIcon(size: 16)
                Text("\(tokenStore.balance)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(AppColor.amber)
                    .monospacedDigit()
                Text("+")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(AppColor.bg)
                    .frame(width: 20, height: 20)
                    .background(AppColor.amber, in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 5)
            // Rozet HER arka planın üstünde okunur olmalı. Keşfet'teki açık/parlak
            // kız fotoğrafları üzerinde eski saydam amber dolgu (opacity 0.12)
            // kayboluyordu — koyu taban + hafif amber ton + gölge ile artık her
            // zeminde (koyu ekran ya da parlak foto) kontrast korunur.
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.black.opacity(0.42))
                    .overlay(RoundedRectangle(cornerRadius: 10).fill(AppColor.amber.opacity(0.14)))
                    .shadow(color: .black.opacity(0.30), radius: 5, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AppColor.amber.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        // Reports the badge's REAL width back to TokenStore — its width isn't
        // fixed (grows with the balance's digit count), so screens that need
        // to reserve space for it (bkz. ChatView.header) read the actual
        // current value instead of guessing a fixed number and getting
        // overlapped once the balance grows past a couple digits.
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { tokenStore.badgeWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, newWidth in tokenStore.badgeWidth = newWidth }
            }
        }
        .overlay(alignment: .topLeading) {
            if let floatingDelta {
                Text(floatingDelta > 0 ? "+\(floatingDelta)" : "\(floatingDelta)")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(floatingDelta > 0 ? Color(hex: 0x34D399) : Color(hex: 0xFF4757))
                    .offset(x: floatingOffsetX, y: floatingOffsetY)
                    .opacity(floatingOpacity)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: tokenStore.lastDelta) { _, newValue in
            guard let newValue else { return }
            // AZALMA (harcama) animasyonsuz — sayı doğrudan düşer. Yüzen etiket
            // sadece KAZANIMDA (+N) gösterilir.
            guard newValue > 0 else { tokenStore.lastDelta = nil; return }
            floatingDelta = newValue
            // Rozetin sol-üst köşesinden başlar, biraz YANA (dışına) doğru
            // kayarak yükselir — doğrudan sayının üstüne binmesin, kolayca
            // görülsün diye (bkz. kullanıcı talebi).
            floatingOffsetX = -14
            floatingOffsetY = -4
            floatingOpacity = 1
            withAnimation(.easeOut(duration: 1.6)) {
                floatingOffsetX = -22
                floatingOffsetY = -34
                floatingOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.65) {
                floatingDelta = nil
                tokenStore.lastDelta = nil
            }
        }
    }
}
