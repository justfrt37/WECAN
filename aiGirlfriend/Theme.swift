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

/// Tasarım renk paleti — "Editorial Rust" (2026-07-03, mor/pembe temadan geçiş).
enum AppColor {
    static let bg = Color(hex: 0x141211)          // koyu arka plan
    static let bg2 = Color(hex: 0x1E1815)         // gradient ortası
    static let pink = Color(hex: 0xC45C3E)        // vurgu / aktif (kavrulmuş turuncu-kiremit)
    static let pinkSoft = Color(hex: 0xE09C78)    // meslek vb. (yumuşak kiremit)
    static let card = Color(hex: 0x241E1C)        // kart
    static let amber = Color(hex: 0xE8A15C)       // gradient ikinci durağı (sıcak altın)
}
