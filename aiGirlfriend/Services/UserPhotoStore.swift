//
//  UserPhotoStore.swift
//  Kullanıcının BOTA gönderdiği fotoğrafları cihazda saklar — Supabase
//  Storage'a HİÇ yüklenmez (botun ürettiği fotoğraflardan farklı olarak,
//  bkz. chat-image/index.ts). VoicePlayer.voiceMessagesDirectory ile aynı
//  desen: Application Support altında kendi klasörü, dosya adı = mesaj UUID'i.
//

import UIKit
import ImageIO

enum UserPhotoStore {
    private static let directory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("UserPhotos", isDirectory: true)

    /// Diskten çözülmüş (küçültülmüş) kullanıcı fotolarının bellek önbelleği —
    /// her redraw'da tam çözünürlüklü fotoyu `Data(contentsOf:)`+`UIImage(data:)`
    /// ile yeniden çözmemek için (path → UIImage). NSCache thread-safe'dir ve
    /// bellek baskısında otomatik boşalır.
    private static let cache = NSCache<NSString, UIImage>()

    /// Verilen fotoğrafı `<uuid>.jpg` olarak kaydeder, göreli dosya adını döner
    /// (bkz. Message.localImagePath). Tam çözünürlük saklanır — sıkıştırma
    /// sadece dosya boyutu için (0.7), Grok'a giden ayrı, küçültülmüş kopya
    /// `base64JPEG(from:)` ile üretilir.
    static func saveUserPhoto(_ image: UIImage, messageID: UUID) -> String? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        let filename = "\(messageID.uuidString).jpg"
        let url = directory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            return nil
        }
    }

    /// `Message.localImagePath`teki göreli dosya adından `UIImage` okur —
    /// ChatBubble'ın çizmesi için. Ağ çağrısı yok, CachedImage/ImageCache
    /// KULLANILMAZ (bu görsel hiç yüklenmedi, sadece cihazda duruyor).
    static func loadUserPhoto(relativePath: String) -> UIImage? {
        let key = relativePath as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let url = directory.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Ekran için makul boyuta KÜÇÜLTEREK çöz (ImageIO thumbnail tam bitmap'i
        // belleğe açmaz) — tam çözünürlük redraw'larda gereksiz RAM tüketiyordu.
        let image = downsample(data) ?? UIImage(data: data)
        if let image {
            let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
            cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }

    /// Ham veriyi ImageIO ile ~1280px uzun kenara küçülterek çözer.
    private static func downsample(_ data: Data, maxPixelDimension: CGFloat = 1280) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Grok'un vision girişine giden, TOKEN MALİYETİNİ sınırlamak için
    /// küçültülmüş base64 JPEG (data: öneki YOK — sunucu ekler, bkz.
    /// chat/index.ts hasUserPhoto). ~1024px kenar, canlı test bu oturumda
    /// standart bir fotoğrafın ~2400 image_token'a mal olduğunu doğruladı —
    /// küçültme bunu bir miktar aşağı çeker.
    static func base64JPEG(from image: UIImage, maxDimension: CGFloat = 1024) -> String? {
        let resized = resize(image, maxDimension: maxDimension)
        guard let data = resized.jpegData(compressionQuality: 0.7) else { return nil }
        return data.base64EncodedString()
    }

    private static func resize(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension else { return image }
        let scale = maxDimension / longestSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
