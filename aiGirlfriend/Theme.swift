//
//  Theme.swift
//  Pencil tasarımındaki renkler ve ortak yardımcılar.
//

import SwiftUI

extension Color {
    /// 0xRRGGBB tam sayısından renk (opaklık 1).
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// Tasarım renk paleti (AIGUI .pen).
enum AppColor {
    static let bg = Color(hex: 0x0F0518)          // koyu arka plan
    static let bg2 = Color(hex: 0x1F0E2E)         // gradient ortası
    static let pink = Color(hex: 0xFF4D8F)        // vurgu / aktif
    static let pinkSoft = Color(hex: 0xFF85B0)    // meslek vb.
    static let card = Color(hex: 0x241433)        // kart
}
