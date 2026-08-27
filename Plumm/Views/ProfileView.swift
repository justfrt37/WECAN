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
import UIKit
import UserNotifications

struct ProfileView: View {
    @Environment(TokenStore.self) private var tokenStore
    @Environment(\.requestReview) private var requestReview
    @Environment(\.openURL) private var openURL

    // Ayarlar (eski SettingsView'den buraya taşındı)
    @State private var notificationsOn = false
    /// uid kopyalandı → ikon kısa süre ✓ olur (bkz. avatarCard).
    @State private var didCopyUID = false
    @State private var showPaywall = false
    private var purchases: PurchaseService { PurchaseService.shared }

    // TODO: gerçek URL'lerle değiştir (App Store / gizlilik / koşullar).
    private let shareURL = URL(string: "https://apps.apple.com/app/id0000000000")!
    private let supportMailURL = URL(string: "mailto:plumappx@protonmail.com")!
    private let cardRadius: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    avatarCard
                    membershipCard
                    settingsSection
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
        .fullScreenCover(isPresented: $showPaywall) { OnboardingPaywallView() }
    }

    // MARK: Üyelik

    /// PRO rozeti/CTA'sı artık SADECE burada görünür — eskiden her sekmede
    /// (Discover/Chat/Explore/Likes) global bir buton olarak nag ediyordu
    /// (bkz. MainTabView, ChatView, kullanıcı talebi). PRO değilse dokununca
    /// paywall açılır; PRO ise sadece durum gösterir, tıklanamaz.
    private var membershipCard: some View {
        Group {
            if purchases.isPro {
                HStack(spacing: 12) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color(hex: 0xFFB938))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(purchases.tier.displayName) Member")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Thanks for supporting Plumm")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                }
                .padding(16)
                .background(AppColor.card, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            } else {
                Button { showPaywall = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Get PRO")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                            Text("Unlock more characters, voice & more")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(16)
                    .background(
                        LinearGradient(colors: [Color(hex: 0xFFAF5C), Color(hex: 0xFF6F61)],
                                       startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Başlık

     private var header: some View {
        HStack {
            Text("Profile")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: Avatar (kimlik bölümü minimal — gerçek kullanıcı verisi yok)

    private var avatarCard: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [AppColor.pink, AppColor.amber],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 88, height: 88)
                Image(systemName: "person.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(.white)
                    .frame(width: 80, height: 80)
                    .background(AppColor.card, in: Circle())
            }
            Text("Guest User")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            // TEMP TESTING (2026-07-12) — Supabase auth UID'sini gösterir
            // (DB satırlarıyla eşleştirme için). Dokununca kopyalar.
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
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [AppColor.bg2, AppColor.card],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: Ayarlar bölümü (inline)

    private var settingsSection: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Ayarlar")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
            }
            .padding(.top, 6)

            notificationsCard

            ShareLink(item: shareURL) {
                row("Share a Friend", trailingIcon: "square.and.arrow.up")
            }
            .buttonStyle(.plain)

            Button { requestReview() } label: {
                HStack {
                    Text("Rate Us")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer()
                    // Tek altın yıldız (bkz. kullanıcı talebi).
                    Image(systemName: "star.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color(hex: 0xFFC24B))
                }
                .padding(.horizontal, 20)
                .frame(height: 66)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: cardRadius))
                .overlay(RoundedRectangle(cornerRadius: cardRadius).strokeBorder(.white.opacity(0.10), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: cardRadius))
            }
            .buttonStyle(.plain)

            Button { openURL(supportMailURL) } label: {
                row("Help & Support", trailingIcon: "envelope.fill")
            }
            .buttonStyle(.plain)

            // Yasal metinler — dış tarayıcıda plummai.com'a açılır (App Store
            // Connect'teki Privacy/Terms URL'leriyle aynı, artık in-app sheet yok).
            Button { openURL(Config.privacyURL) } label: {
                row("Privacy Policy", trailingIcon: "lock.shield.fill")
            }
            .buttonStyle(.plain)

            Button { openURL(Config.termsURL) } label: {
                row("Terms of Use", trailingIcon: "doc.text.fill")
            }
            .buttonStyle(.plain)
        }
    }

    private var notificationsCard: some View {
        HStack(spacing: 12) {
            Text("Notifications")
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

    private func row(_ title: String, trailingIcon: String? = nil, trailingTint: Color = .white.opacity(0.8)) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
            if let trailingIcon {
                Image(systemName: trailingIcon)
                    .font(.system(size: 16))
                    .foregroundStyle(trailingTint)
            }
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
