//
//  OnboardingPaywallView.swift
//  ONB6 — abonelik paywall'ı. "O bekliyor" ekranından sonra gelir.
//  Arka planda ONB3'te seçilen kızın videosu (bulanık) oynar — "kilidini aç"
//  fikrini pekiştirir. Pencil "PAYWALL" mockup'ının uygulama karşılığı.
//

import SwiftUI

struct OnboardingPaywallView: View {
    @Environment(OnboardingStore.self) private var onboarding
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// X (kapat) butonu 2 sn sonra belirir — kullanıcı önce paywall'ı görsün.
    @State private var showClose = false

    private let privacyURL = URL(string: "https://wecan.app/privacy")!
    private let termsURL = URL(string: "https://wecan.app/terms")!

    /// Kapatma: onboarding adımı olarak açıldıysa complete(), bir cover olarak
    /// (PRO butonundan) açıldıysa dismiss() — ikisini de çağırmak güvenli.
    private func close() {
        dismiss()
        onboarding.complete()
    }

    /// Seçili paket — varsayılan yıllık (en avantajlı).
    private enum Plan { case weekly, yearly }
    @State private var plan: Plan = .yearly

    /// Arkada oynayacak video — ONB3'te seçilen kızınki (yoksa varsayılan).
    private var bgVideo: String {
        onboarding.selectedCharacter?.selectedVideo ?? "onb4Video"
    }

    private let features: [String] = [
        "Sesli konuşma",
        "Sınırsız fotoğraf",
        "Kendi kızını yarat",
        "Sınırsız erişim (7/24)",
        "Uzun süreli bellek",
    ]

    var body: some View {
        ZStack {
            // Seçilen kızın videosu — bulanık + karartma ("kilidini aç" hissi).
            LoopingVideoPlayer(resourceName: bgVideo)
                .id(bgVideo)
                .ignoresSafeArea()
                .blur(radius: 6)
                .overlay(scrim.ignoresSafeArea())

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                content
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeIn(duration: 0.4)) { showClose = true }
        }
    }

    // MARK: Üst bar (X + logo PRO)

    private var topBar: some View {
        ZStack {
            OBBrandMarkPro()
            HStack {
                Button { close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 30, height: 30)
                }
                .opacity(showClose ? 1 : 0)
                .disabled(!showClose)
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    // MARK: Alt içerik

    private var content: some View {
        VStack(spacing: 22) {
            Text("Kızının kilidini aç")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 8, y: 2)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(features, id: \.self) { f in
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color(hex: 0x34D399))
                        Text(f)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 30)

            HStack(spacing: 14) {
                planCard(.weekly, title: "Haftalık", price: "₺149,99", sub: "hafta başına", badge: nil)
                planCard(.yearly, title: "Yıllık", price: "₺1.499,99", sub: "₺28,85 / hafta", badge: "%80 tasarruf")
            }
            .padding(.top, 10)   // üste taşan tasarruf rozetine yer

            Button { close() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "lock.open.fill").font(.system(size: 19, weight: .bold))
                    Text("Kilidi Aç").font(.system(size: 20, weight: .heavy))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 62)
                .background(OBTheme.buttonGradient, in: RoundedRectangle(cornerRadius: 20))
            }

            legalRow
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)   // buton yere daha yakın olsun
    }

    private func planCard(_ p: Plan, title: String, price: String, sub: String, badge: String?) -> some View {
        let selected = plan == p
        return Button { plan = p } label: {
            // Her iki kart AYNI içerik (başlık/fiyat/alt) → eşit boy. Rozet
            // layout dışında, üste taşan overlay olarak durur (boyu etkilemez).
            VStack(spacing: 5) {
                Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                Text(price).font(.system(size: 22, weight: .heavy)).foregroundStyle(.white)
                Text(sub).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18).padding(.horizontal, 8)
            .background(
                (selected ? OBTheme.coral.opacity(0.16) : Color.white.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: 20)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(selected ? OBTheme.coral : .white.opacity(0.18),
                                  lineWidth: selected ? 2.5 : 1.5)
            )
            .overlay(alignment: .top) {
                if let badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(OBTheme.buttonGradient, in: Capsule())
                        .offset(y: -11)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Butonun altındaki yasal linkler — Gizlilik, Koşullar, Geri Yükle.
    private var legalRow: some View {
        HStack(spacing: 16) {
            Button("Gizlilik Politikası") { openURL(privacyURL) }
            Button("Kullanım Koşulları") { openURL(termsURL) }
            Button("Geri Yükle") { restore() }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.5))
        .buttonStyle(.plain)
    }

    private func restore() {
        // TODO: RevenueCat bağlanınca gerçek "restore purchases". Şimdilik
        // entitlement yenilemeyi tetikler (RevenueCat yoksa etkisiz).
        Task { await PurchaseService.shared.refreshEntitlement() }
    }

    /// Video üstü karartma — metni okunur kılar.
    private var scrim: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(hex: 0x0E060A, alpha: 0.30), location: 0.0),
                .init(color: Color(hex: 0x0E060A, alpha: 0.35), location: 0.35),
                .init(color: Color(hex: 0x140810, alpha: 0.82), location: 0.60),
                .init(color: Color(hex: 0x0C0509, alpha: 0.97), location: 1.0),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }
}

/// "❤ Plumm PRO" logo satırı — normal OBBrandMark + PRO rozeti.
private struct OBBrandMarkPro: View {
    var body: some View {
        HStack(spacing: 8) {
            OBBrandMark(size: 22)
            Text("PRO")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(OBTheme.buttonGradient, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
