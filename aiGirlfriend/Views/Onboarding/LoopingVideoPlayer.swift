//
//  LoopingVideoPlayer.swift
//  Onboarding arka planları için: bundle'daki bir videoyu SESSİZ, sonsuz
//  döngüde, ekranı dolduracak şekilde (aspect-fill) oynatır.
//  ONB1'in arka planı (ob1Video) ve ileride ONB3 kartları/seçim videoları
//  bu view ile gösterilir.
//

import SwiftUI
import UIKit
import AVFoundation

/// SwiftUI sarmalayıcı. `resourceName` uzantısız dosya adı (ör. "ob1Video").
struct LoopingVideoPlayer: UIViewRepresentable {
    let resourceName: String
    var fileExtension: String = "mp4"

    func makeUIView(context: Context) -> LoopingVideoUIView {
        LoopingVideoUIView(resourceName: resourceName, fileExtension: fileExtension)
    }

    func updateUIView(_ uiView: LoopingVideoUIView, context: Context) {}
}

/// Katmanı `AVPlayerLayer` olan UIView — video doğrudan layer'a çizilir.
/// `AVQueuePlayer` + `AVPlayerLooper` ile kesintisiz döngü sağlanır.
final class LoopingVideoUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    private let queuePlayer = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init(resourceName: String, fileExtension: String) {
        super.init(frame: .zero)

        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.player = queuePlayer
        queuePlayer.isMuted = true
        // Sistem ses oturumunu ele geçirmesin (müzik çalıyorsa kesmesin).
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false

        guard let url = Bundle.main.url(forResource: resourceName, withExtension: fileExtension) else {
            assertionFailure("LoopingVideoPlayer: '\(resourceName).\(fileExtension)' bundle'da bulunamadı")
            return
        }

        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        queuePlayer.play()

        // Uygulama arka plandan dönünce oynatmayı sürdür (iOS videoyu duraklatır).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resume),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmıyor") }

    @objc private func resume() {
        queuePlayer.play()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
