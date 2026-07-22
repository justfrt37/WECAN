//
//  ImageCache.swift
//  Karakter görselleri için iki katmanlı cache: bellek (NSCache — bellek
//  baskısında/uyarısında otomatik boşalır) + disk (Caches/ImageCache, kalıcı;
//  aynı fotoğraflar tekrar tekrar sunucudan indirilmez).
//
//  RAM ayak izi (bkz. talep: "görünmeyen fotolar bile RAM tutuyor"):
//   - Görseller belleğe alınmadan ÖNCE ekran boyutuna KÜÇÜLTÜLÜR (downsample,
//     ImageIO). 4000×6000 bir foto tam çözülünce ~96MB tutar; ~1280px'e
//     küçültünce ~5MB. Chat/feed zaten ~220-400px gösteriyor, kayıp yok.
//   - NSCache adet + maliyet sınırlı; bellek uyarısında tamamen boşaltılır.
//     (Eski hal: 256MB limit + tam çözünürlük → RAM şişiyordu.)
//

import UIKit
import CryptoKit
import ImageIO

final class ImageCache {
    static let shared = ImageCache()
    private init() {
        cache.totalCostLimit = 48 * 1024 * 1024  // ~48 MB (eski 256MB çok yüksekti)
        cache.countLimit = 60                      // en fazla ~60 görsel bellekte
        try? FileManager.default.createDirectory(at: diskCacheDir, withIntermediateDirectories: true)
        // Bellek baskısında belleği tamamen bırak (disk kalır, gerekince tekrar okunur).
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.cache.removeAllObjects() }
    }

    // NSCache thread-safe'dir.
    private let cache = NSCache<NSString, UIImage>()

    /// Belleğe/diske alınan görsellerin uzun kenarı bu piksele düşürülür.
    /// Tam ekran görüntüleme için fazlasıyla yeterli, RAM için makul.
    private let maxPixelDimension: CGFloat = 1280

    private let diskCacheDir: URL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ImageCache", isDirectory: true)

    /// URL'den, uygulama yeniden başlatılsa bile AYNI kalan bir dosya adı
    /// üretir (Swift'in `hashValue`'su process başına rastgele olduğu için
    /// dosya adı olarak KULLANILAMAZ — SHA256 kullanılır).
    private func diskPath(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return diskCacheDir.appendingPathComponent(hex)
    }

    /// Ham veriyi ekran için makul boyuta KÜÇÜLTEREK çözer (RAM tasarrufu).
    /// ImageIO thumbnail tam bitmap'i belleğe açmadan doğrudan küçük çözer.
    func decode(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cg)
    }

    /// Bellekte varsa oradan; yoksa diskten (küçültülmüş halde saklı) okur ve
    /// belleğe de alır. İkisinde de yoksa nil — çağıran taraf ağdan indirir.
    func image(for url: URL) -> UIImage? {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = try? Data(contentsOf: diskPath(for: url)),
              let img = UIImage(data: data) else { return nil }
        insertMemoryOnly(img, for: url)
        return img
    }

    /// Ağdan gelen ham veriyi KÜÇÜLTÜP hem belleğe hem diske koyar; küçültülmüş
    /// UIImage'ı döndürür (çağıran doğrudan gösterebilir).
    @discardableResult
    func insert(data: Data, for url: URL) -> UIImage? {
        guard let image = decode(data) else { return nil }
        insertMemoryOnly(image, for: url)
        let path = diskPath(for: url)
        Task.detached(priority: .background) {
            // Diske de KÜÇÜLTÜLMÜŞ hali yazılır (jpeg — png'den küçük/hızlı).
            guard let out = image.jpegData(compressionQuality: 0.85) else { return }
            try? out.write(to: path, options: .atomic)
        }
        return image
    }

    /// Elde zaten (makul boyutta) bir UIImage varsa. Küçültme atlanır.
    func insert(_ image: UIImage, for url: URL) {
        insertMemoryOnly(image, for: url)
        let path = diskPath(for: url)
        Task.detached(priority: .background) {
            guard let out = image.jpegData(compressionQuality: 0.85) else { return }
            try? out.write(to: path, options: .atomic)
        }
    }

    private func insertMemoryOnly(_ image: UIImage, for url: URL) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        cache.setObject(image, forKey: url.absoluteString as NSString, cost: cost)
    }

    /// Verilen URL'leri eş zamanlı indirip (küçültüp) cache'e koyar. Zaten
    /// bellekte/diskte olanları atlar. Splash'te `await` ile çağrılır.
    func prefetch(_ urls: [URL]) async {
        await withTaskGroup(of: Void.self) { group in
            for url in urls where image(for: url) == nil {
                group.addTask {
                    guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
                    ImageCache.shared.insert(data: data, for: url)
                }
            }
        }
    }
}
