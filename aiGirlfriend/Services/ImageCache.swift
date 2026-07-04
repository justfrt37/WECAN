//
//  ImageCache.swift
//  Karakter görselleri için iki katmanlı cache: bellek (NSCache, hızlı ama
//  process kapanınca sıfırlanır) + disk (Caches/ImageCache, uygulama her
//  açıldığında kalıcı — aynı fotoğraflar tekrar tekrar sunucudan indirilmez).
//  Splash'te tüm görseller önceden indirilir; feed'de "yükleniyor" görünmez.
//

import UIKit
import CryptoKit

final class ImageCache {
    static let shared = ImageCache()
    private init() {
        cache.totalCostLimit = 256 * 1024 * 1024 // ~256 MB (bellek)
        try? FileManager.default.createDirectory(at: diskCacheDir, withIntermediateDirectories: true)
    }

    // NSCache thread-safe'dir.
    private let cache = NSCache<NSString, UIImage>()

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

    /// Bellekte varsa oradan; yoksa diskten (varsa) okur ve belleğe de alır.
    /// İkisinde de yoksa nil — çağıran taraf (CachedImage/prefetch) ağdan indirir.
    func image(for url: URL) -> UIImage? {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = try? Data(contentsOf: diskPath(for: url)),
              let img = UIImage(data: data) else { return nil }
        insertMemoryOnly(img, for: url)
        return img
    }

    func insert(_ image: UIImage, for url: URL) {
        insertMemoryOnly(image, for: url)
        let path = diskPath(for: url)
        Task.detached(priority: .background) {
            guard let data = image.pngData() else { return }
            try? data.write(to: path, options: .atomic)
        }
    }

    private func insertMemoryOnly(_ image: UIImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: url.absoluteString as NSString, cost: cost)
    }

    /// Verilen URL'leri eş zamanlı indirip cache'e koyar. Zaten bellekte/diskte
    /// olanları atlar. Splash'te `await` ile çağrılır.
    func prefetch(_ urls: [URL]) async {
        await withTaskGroup(of: Void.self) { group in
            for url in urls where image(for: url) == nil {
                group.addTask {
                    guard let (data, _) = try? await URLSession.shared.data(from: url),
                          let img = UIImage(data: data) else { return }
                    ImageCache.shared.insert(img, for: url)
                }
            }
        }
    }
}
