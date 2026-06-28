//
//  ImageCache.swift
//  Karakter görselleri için bellek içi cache.
//  Splash'te tüm görseller önceden indirilir; feed'de "yükleniyor" görünmez.
//

import UIKit

final class ImageCache {
    static let shared = ImageCache()
    private init() {
        cache.totalCostLimit = 256 * 1024 * 1024 // ~256 MB
    }

    // NSCache thread-safe'dir.
    private let cache = NSCache<NSString, UIImage>()

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    func insert(_ image: UIImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: url.absoluteString as NSString, cost: cost)
    }

    /// Verilen URL'leri eş zamanlı indirip cache'e koyar. Zaten cache'te
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
