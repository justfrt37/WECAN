//
//  OnboardingTheme.swift
//  Onboarding ekranlarının renk/gradient paleti — Pencil "Plumm" mockup'ından.
//  Uygulamanın geri kalanı AppColor (Midnight Velvet) kullanır; onboarding
//  ise kendi koyu zemin + mercan/şeftali vurgusuyla ayrışır.
//

import SwiftUI
import UIKit

extension Image {
    /// Bundle'daki loose (asset catalog dışı) bir resim dosyasını yükler.
    /// Onboarding arka planları (onb3_bg.jpg, onb5_bg.png) için.
    init(bundleResource name: String, ext: String) {
        if let url = Bundle.main.url(forResource: name, withExtension: ext),
           let ui = UIImage(contentsOfFile: url.path) {
            self = Image(uiImage: ui)
        } else {
            self = Image(systemName: "photo")
        }
    }
}

enum OBTheme {
    /// Splash + onboarding düz zemini (#140810).
    static let bg = Color(hex: 0x140810)

    /// Marka vurgusu — kalp ikonu, aktif durumlar (#FF6F61).
    static let coral = Color(hex: 0xFF6F61)
    /// Gradient üst durağı — sıcak şeftali (#FFAF5C).
    static let peach = Color(hex: 0xFFAF5C)

    /// "Devam et" gibi ana buton dolgusu (şeftali → mercan, yukarıdan aşağı).
    static let buttonGradient = LinearGradient(
        colors: [peach, coral],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Video arka planların üstüne binen karartma — metni okunur kılar.
    /// Pencil "karartma" katmanının birebir karşılığı (üst yarı-koyu, orta
    /// açık, alt tam koyu).
    static let scrim = LinearGradient(
        stops: [
            .init(color: Color(hex: 0x0E060A, alpha: 0.70), location: 0.0),
            .init(color: Color(hex: 0x0E060A, alpha: 0.40), location: 0.35),
            .init(color: Color(hex: 0x140810, alpha: 0.95), location: 0.72),
            .init(color: Color(hex: 0x0C0509, alpha: 1.0),  location: 1.0),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Marka adı — Pencil'de "Inter" kullanılıyor ama uygulama Inter'ı bundle
    /// etmiyor; sistem fontu (SF Pro) heavy/bold ile görsel olarak yakın.
    static let brandName = "Plumm"
}

/// Splash ve ONB üstlerinde kullanılan "❤ Plumm" logo satırı.
struct OBBrandMark: View {
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: size * 0.28) {
            Image(systemName: "heart.fill")
                .font(.system(size: size * 0.9))
                .foregroundStyle(OBTheme.coral)
            Text(OBTheme.brandName)
                .font(.system(size: size, weight: .heavy))
                .foregroundStyle(.white)
                .tracking(0.5)
        }
    }
}
