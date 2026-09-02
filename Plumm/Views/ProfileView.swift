//
//  ProfileView.swift
//  "Profil" sekmesi. Ayarlar (bildirimler, uygulama kilidi, öner/değerlendir,
//  yardım, gizlilik, koşullar, verileri sil) artık ayrı bir sayfa değil —
//  hepsi bu sekmenin altına inline yerleştirildi.
//  Not: Uygulama sadece anonim girişle çalışıyor (gerçek kimlik verisi yok) —
//  kimlik bölümü minimal tutuldu.
//

import SwiftUI
import StoreKit
import TipKit
import UIKit
import UserNotifications

struct ProfileView: View {
    @Environment(TokenStore.self) private var tokenStore
    @Environment(\.requestReview) private var requestReview
    @Environment(\.openURL) private var openURL

    // Ayarlar (eski SettingsView'den buraya taşındı)
    @State private var notificationsOn = false
    @State private var showCosts = false
    /// uid kopyalandı → ikon kısa süre ✓ olur (bkz. avatarCard).
    @State private var didCopyUID = false

    // TODO: gerçek URL'lerle değiştir (App Store / gizlilik / koşullar).
    private let shareURL = URL(string: "https://apps.apple.com/app/id0000000000")!
    private let supportMailURL = URL(string: "mailto:plumappx@protonmail.com")!
    private let cardRadius: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    // Sayfa yalnızca ayarlardan ibaret: avatar kartı (kişi
                    // ikonu + "Guest User") ve üyelik kartı kaldırıldı, geriye
                    // kalan tek bilgi olan UID en altta (bkz. kullanıcı talebi).
                    settingsSection
                    userIdFooter
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 96)   // tab bar payı
            }
            .scrollIndicators(.hidden)
        }
        .background(
            LinearGradient(colors: [AppColor.bg, AppColor.bg2, AppColor.bg],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .task { notificationsOn = await currentNotificationStatus() }
        .sheet(isPresented: $showCosts) { TokenCostsView() }
    }

    // MARK: Üyelik — KALDIRILDI
    //
    // `membershipCard` tamamen silindi: PRO değilken turuncu "Get PRO" CTA'sı,
    // PRO'yken de "Max Member" durum kartı gösteriyordu. İkisi de istenmedi —
    // bu sayfada üyelikle ilgili hiçbir şey yazmıyor (bkz. kullanıcı talebi).
    // Dönüşüm yolu her sekmenin sağ üstündeki PRO butonu (bkz. MainTabView).

    // MARK: Başlık

     private var header: some View {
        HStack {
            // Sayfa başlığı sekmeyle aynı: "Settings" (bkz. MainTab.titleKey).
            Text("Settings")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: Avatar (kimlik bölümü minimal — gerçek kullanıcı verisi yok)

    /// TEMP TESTING (2026-07-12) — Supabase auth UID'si (DB satırlarıyla
    /// eşleştirmek için). Dokununca kopyalar. Eskiden sayfanın TEPESİNDEki
    /// avatar kartındaydı; o kart (kişi ikonu + "Guest User") kaldırılınca
    /// buraya, en alta taşındı (bkz. kullanıcı talebi).
    private var userIdFooter: some View {
        Group {
            if let uid = UserDefaultsManager.shared.userId {
                Button {
                    UIPasteboard.general.string = uid
                    withAnimation { didCopyUID = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation { didCopyUID = false }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(uid)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                        Image(systemName: didCopyUID ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(didCopyUID ? Color(hex: 0x22C55E) : .white.opacity(0.55))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        // Kart değil, sade bir alt bilgi: eskiden avatar kartının içindeydi ve
        // o kartın gradient/çerçevesini paylaşıyordu. Sayfanın en altında bir
        // teşhis satırı olarak durması yeterli, dikkat çekmesi gerekmiyor.
        .padding(.top, 10)
        .frame(maxWidth: .infinity)
    }

    // MARK: Ayarlar bölümü (inline)

    private var settingsSection: some View {
        VStack(spacing: 14) {
            // Bölüm etiketi kaldırıldı: sayfa başlığı zaten "Settings",
            // hemen altında ikinci kez tekrar ediyordu. Etiket gidince ilk
            // kart başlığa fazla yaklaştı — 7pt nefes payı (bkz. kullanıcı talebi).
            notificationsCard
                .padding(.top, 7)

            ShareLink(item: shareURL) {
                row("Share a Friend")
            }
            .buttonStyle(.plain)

            Button { requestReview() } label: {
                HStack {
                    // verbatim: bkz. notificationsCard'daki not.
                    // Altın yıldız da kaldırıldı — diğer satırlardaki ikonlarla
                    // birlikte (bkz. kullanıcı talebi).
                    Text(verbatim: "Rate Us")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .frame(height: 66)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: cardRadius))
                .overlay(RoundedRectangle(cornerRadius: cardRadius).strokeBorder(.white.opacity(0.10), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: cardRadius))
            }
            .buttonStyle(.plain)

            Button { showCosts = true } label: {
                row("Token costs")
            }
            .buttonStyle(.plain)

            Button { openURL(supportMailURL) } label: {
                row("Help & Support")
            }
            .buttonStyle(.plain)

            #if DEBUG
            Button { PlummTips.reset() } label: {
                row("Reset feature tips")
            }
            .buttonStyle(.plain)
            #endif

            // Yasal metinler — dış tarayıcıda plummai.com'a açılır (App Store
            // Connect'teki Privacy/Terms URL'leriyle aynı, artık in-app sheet yok).
            Button { openURL(Config.privacyURL) } label: {
                row("Privacy Policy")
            }
            .buttonStyle(.plain)

            Button { openURL(Config.termsURL) } label: {
                row("Terms of Use")
            }
            .buttonStyle(.plain)
        }
    }

    private var notificationsCard: some View {
        HStack(spacing: 12) {
            // verbatim: cihaz dili Türkçeyken katalog bunu "Bildirimler" yapıyordu;
            // bu iki satırın İngilizce kalması istendi (bkz. kullanıcı talebi).
            Text(verbatim: "Notifications")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
            // Sadece toggle — sağa doğru ok (konuştuğun kişilerin bildirim
            // ayarları ekranına giden chevron) kaldırıldı (bkz. kullanıcı talebi).
            Toggle("", isOn: $notificationsOn)
                .labelsHidden()
                .tint(AppColor.pink)
                .onChange(of: notificationsOn) { _, wantsOn in
                    Task { await handleNotificationToggle(wantsOn) }
                }
        }
        .padding(.horizontal, 20)
        .frame(height: 66)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: cardRadius))
        .overlay(RoundedRectangle(cornerRadius: cardRadius).strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }

    /// Ayar satırı — sağdaki ikonlar kaldırıldı (bkz. kullanıcı talebi),
    /// geriye yalnızca metin kalıyor. `Spacer()` duruyor ki satır tam
    /// genişlikte kalsın ve dokunma hedefi daralmasın.
    private func row(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 66)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: cardRadius))
        .overlay(RoundedRectangle(cornerRadius: cardRadius).strokeBorder(.white.opacity(0.10), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: cardRadius))
    }

    // MARK: Ayarlar aksiyonları

    private func currentNotificationStatus() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
    }

    /// Açmaya çalışırsa iOS izni ister; kapatmaya çalışırsa (iOS uygulama içinden
    /// izni geri alamadığı için) sistem Ayarları'na yönlendirir.
    private func handleNotificationToggle(_ wantsOn: Bool) async {
        if wantsOn {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            notificationsOn = granted
        } else {
            notificationsOn = false
            if let url = URL(string: UIApplication.openSettingsURLString) {
                await UIApplication.shared.open(url)
            }
        }
    }

}

#Preview {
    ProfileView()
}
