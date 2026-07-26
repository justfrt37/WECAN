//
//  CachedImage.swift
//  ImageCache'ten anında gösteren görsel view'i.
//  Cache'te varsa hiç "yükleniyor" göstermez (init'te senkron okur).
//

import SwiftUI

struct CachedImage<Content: View, Placeholder: View>: View {
    private let url: URL?
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    @State private var uiImage: UIImage?

    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
        // Bellekte (NSCache) hazırsa ilk render'da göster — spinner/flaş olmaz.
        // SADECE bellek: init view kurulumunda çalışır, burada disk okuma/çözme
        // (Data(contentsOf:)/UIImage(data:)) ANA THREAD'i bloklardı — o iş
        // async load yoluna taşındı.
        _uiImage = State(initialValue: url.flatMap { ImageCache.shared.memoryImage(for: $0) })
    }

    var body: some View {
        Group {
            if let uiImage {
                content(Image(uiImage: uiImage))
            } else {
                placeholder()
            }
        }
        .task(id: url) { await load(for: url) }
    }

    /// `url` parametresi açıkça alınır: view reuse edildiğinde (örn. feed kartı
    /// değişince) eski @State uiImage kalıp yeni foto hiç yüklenmiyordu —
    /// id değişince state'i burada senkron sıfırlıyoruz.
    private func load(for url: URL?) async {
        // 1) Bellek (NSCache) — ucuz, senkron; state'i url değişiminde sıfırlar.
        uiImage = url.flatMap { ImageCache.shared.memoryImage(for: $0) }
        guard uiImage == nil, let url else { return }

        // 2) Disk okuma + çözme ANA THREAD DIŞINDA — Data(contentsOf:)/ImageIO
        //    bloklayıcı; sonucu ana aktörde uiImage'a yaz.
        let fromDisk = await Task.detached(priority: .userInitiated) {
            ImageCache.shared.image(for: url)
        }.value
        if let fromDisk {
            if self.url == url { uiImage = fromDisk }
            return
        }

        // 3) Ağdan indir (timeout ~20s) + çöz/insert yine ana thread dışında.
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return }
        let img = await Task.detached(priority: .userInitiated) {
            // ImageCache içinde ekran boyutuna KÜÇÜLTÜLÜR (RAM tasarrufu).
            ImageCache.shared.insert(data: data, for: url)
        }.value
        if let img, self.url == url { uiImage = img }
    }
}
