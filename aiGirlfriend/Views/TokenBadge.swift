//
//  TokenBadge.swift
//  Her ekranda görünmesi gereken kalıcı token rozeti — sayı + "+" kutusu,
//  hepsi TEK dokunma hedefi (bkz. design doc: "Not two separate tap targets").
//  `tokenStore.lastDelta` her değiştiğinde küçük bir "+1000"/"-25" animasyonu
//  gösterir (bkz. TokenStore.setBalance) — harcama/kazanma her zaman görünür olsun diye.
//

import SwiftUI

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
                Text("💠 \(tokenStore.balance)")
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
            .background(AppColor.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AppColor.amber.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
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
