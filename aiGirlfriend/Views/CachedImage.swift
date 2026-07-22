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
        // Cache'te hazırsa ilk render'da göster — spinner/flaş olmaz.
        _uiImage = State(initialValue: url.flatMap { ImageCache.shared.image(for: $0) })
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
        uiImage = url.flatMap { ImageCache.shared.image(for: $0) }
        guard uiImage == nil, let url else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              // ImageCache içinde ekran boyutuna KÜÇÜLTÜLÜR (RAM tasarrufu).
              let img = ImageCache.shared.insert(data: data, for: url) else { return }
        if self.url == url { uiImage = img }
    }
}
