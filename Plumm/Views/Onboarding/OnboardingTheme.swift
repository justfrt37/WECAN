//
//  OnboardingTheme.swift
//  Onboarding ekranlarının renk/gradient paleti — Pencil "Plumm" mockup'ından.
//  Uygulamanın geri kalanı AppColor (Midnight Velvet) kullanır; onboarding
//  ise kendi koyu zemin + mercan/şeftali vurgusuyla ayrışır.
//

import SwiftUI
import UIKit
import ImageIO

extension Image {
    /// Decode edilen UIImage'ların küçük önbelleği — kaynak adına göre anahtarlı.
    /// Eskiden `init` her body değerlendirmesinde (Explore kategori geçişleri,
    /// ONB5 basılı-tut etkileşimi vb.) diskten TAM çözünürlükte yeniden decode
    /// ediyordu; artık ilk seferde decode edilip burada tutulur.
    private static let bundleImageCache = NSCache<NSString, UIImage>()

    /// Bundle'daki loose (asset catalog dışı) bir resim dosyasını yükler.
    /// Onboarding arka planları (onb3_bg.jpg, onb5_bg.png) için.
    /// İlk çağrıda ekran için makul boyuta indirilip decode edilir ve önbelleğe
    /// alınır; sonraki çağrılar önbellekten döner (yeniden decode yok).
    init(bundleResource name: String, ext: String) {
        let key = "\(name).\(ext)" as NSString
        if let cached = Image.bundleImageCache.object(forKey: key) {
            self = Image(uiImage: cached)
            return
        }
        if let url = Bundle.main.url(forResource: name, withExtension: ext),
           let ui = Image.decodeDownsampled(at: url) {
            Image.bundleImageCache.setObject(ui, forKey: key)
            self = Image(uiImage: ui)
        } else {
            self = Image(systemName: "photo")
        }
    }

    /// Görseli ekranın en büyük kenarına göre (piksel bazında) indirerek TEK
    /// sefer decode eder (ImageIO thumbnail). Tam çözünürlüğü her seferinde
    /// decode etmek yerine — tam ekran arka planlar için bu boyut fazlasıyla
    /// yeterli, RAM/CPU maliyeti çok daha düşük.
    private static func decodeDownsampled(at url: URL) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL,
                                                    [kCGImageSourceShouldCache: false] as CFDictionary) else {
            // ImageIO açılamazsa eski davranışa düş (en azından görsel gösterilir).
            return UIImage(contentsOfFile: url.path)
        }
        let bounds = UIScreen.main.bounds
        let maxPixel = max(bounds.width, bounds.height) * UIScreen.main.scale
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return UIImage(contentsOfFile: url.path)
        }
        return UIImage(cgImage: cg)
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

    /// TÜM onboarding ekranlarının ortak yatay kenar boşluğu. Ekranlar tek tek
    /// 20/22/24/28 gibi farklı değerler kullanıyordu, içerik kimi ekranda kenara
    /// yapışık duruyordu (bkz. kullanıcı talebi). Tek kaynak burası — cihaz
    /// genişliğinden bağımsız olarak her ekranda aynı nefes payı kalır.
    static let screenPadding: CGFloat = 24
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
