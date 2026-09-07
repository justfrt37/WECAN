//
//  KeyboardDismisser.swift
//  Klavye dışında bir yere dokununca klavyeyi kapatır (bkz. kullanıcı talebi).
//
//  NEDEN PENCERE SEVİYESİNDE: metin alanı altı ayrı ekranda var (ChatView,
//  ChatListView arama, CreateCharacterView, AddCharacterNoteSheet,
//  VoiceCallView, OnboardingNameView). Her birine tek tek `.onTapGesture`
//  eklemek hem tekrar hem de risk: SwiftUI'de arka plana konan bir tap
//  jesti, üstündeki butonların/hücrelerin dokunuşlarını yutabiliyor
//  (bkz. ExploreView'deki hücre-dokunuş vakası). Pencereye takılan bir
//  UITapGestureRecognizer `cancelsTouchesInView = false` ile çalışır: jest
//  dokunuşu TÜKETMEZ, altındaki her kontrol normal davranmaya devam eder,
//  biz sadece "bir yere dokunuldu" bilgisini alıp klavyeyi kapatırız.
//
//  Metin alanının KENDİSİNE dokunmak hariç tutuluyor — aksi halde odaklanmak
//  için alana dokunmak klavyeyi açıp aynı anda kapatmaya çalışırdı.
//

import UIKit
import OSLog

final class KeyboardDismisser: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismisser()
    private static let diag = Logger(subsystem: "com.firat.Plumm", category: "keyboard")

    private weak var installedWindow: UIWindow?

    /// Idempotent: aynı pencereye ikinci jest takılmaz. Pencere henüz yoksa
    /// (çok erken çağrı) sessizce çıkar — `.onChange(scenePhase)` bir sonraki
    /// aktif oluşta tekrar dener.
    func install() {
        guard installedWindow == nil else { return }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else { return }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        // Kritik: dokunuş tüketilmez, yalnızca gözlemlenir.
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
        installedWindow = window
        Self.diag.log("klavye kapatma jesti pencereye takıldı")
    }

    @objc private func handleTap() {
        installedWindow?.endEditing(true)
    }

    // MARK: - UIGestureRecognizerDelegate

    /// Dokunuş bir metin girişinin (ya da onun içindeki bir alt görünümün)
    /// üzerindeyse jest hiç başlamaz: alana odaklanmak için yapılan dokunuş
    /// klavyeyi kapatmamalı. Kopyala/yapıştır menüsü ve seçim tutamaçları da
    /// UITextInput hiyerarşisinin içinde olduğu için aynı kontrolle korunur.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !isTextInput(touch.view)
    }

    /// Diğer jestlerle (kaydırma, buton dokunuşu, uzun basma) birlikte
    /// çalışsın — biri diğerini iptal etmesin.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    private func isTextInput(_ view: UIView?) -> Bool {
        var current = view
        while let v = current {
            if v is UITextField || v is UITextView || v is UITextInput { return true }
            // Klavyenin kendisi ayrı bir pencerede yaşar ama emin olmak için
            // sistem giriş görünümlerini de dışarıda bırakıyoruz.
            if String(describing: type(of: v)).hasPrefix("UIKB") { return true }
            current = v.superview
        }
        return false
    }
}
