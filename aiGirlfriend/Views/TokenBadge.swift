//
//  TokenBadge.swift
//  Her ekranda görünmesi gereken kalıcı token rozeti — sayı + "+" kutusu,
//  hepsi TEK dokunma hedefi (bkz. design doc: "Not two separate tap targets").
//

import SwiftUI

struct TokenBadge: View {
    let balance: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text("💠 \(balance)")
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
    }
}
