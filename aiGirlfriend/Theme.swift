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

/// Tasarım renk paleti — "Midnight Velvet" (2026-07-08, Whisper Dark'tan geçiş).
/// Deep plum/burgundy ground + warm gold accent. `pink` stays the
/// background-safe accent (deep burgundy-rose — white text on top of it
/// needs to stay legible everywhere it's already used as a solid fill:
/// buttons, badges, capsules). `amber` carries the actual warm GOLD from the
/// "Midnight Velvet" mock — used in gradients/icons/foreground accents, and
/// anywhere a solid gold fill needs DARK text on top (gold + white text
/// fails contrast, see the chat "me" bubble in ChatView which already uses
/// `AppColor.bg` as its foreground for exactly this reason).
enum AppColor {
    static let bg = Color(hex: 0x220A16)          // koyu arka plan (derin bordo-siyah) — resmi app zemini
    static let bg2 = Color(hex: 0x33101F)         // gradient ortası (daha açık bordo)
    static let pink = Color(hex: 0x7A2F42)        // vurgu / aktif (koyu bordo-gül — beyaz üstünde kontrast için)
    static let pinkSoft = Color(hex: 0xE8C9A0)    // meslek vb. (yumuşak altın-bej, sadece metin/ikon)
    static let card = Color(hex: 0x4A1226)        // kart (derin bordo)
    static let amber = Color(hex: 0xD4A574)       // sıcak ALTIN — gradient ikinci durağı + solid gold dolgu
}
