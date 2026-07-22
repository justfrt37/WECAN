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

    // TODO: gerçek URL'lerle değiştir (App Store / gizlilik / koşullar).
    private let shareURL = URL(string: "https://apps.apple.com/app/id0000000000")!
    private let supportMailURL = URL(string: "mailto:destek@wecan.app")!
    private let cardRadius: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    avatarCard
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
                Text(uid)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .onTapGesture {
                        UIPasteboard.general.string = uid
                    }
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
                row("Arkadaşına Öner", trailingIcon: "square.and.arrow.up")
            }
            .buttonStyle(.plain)

            Button { requestReview() } label: {
                HStack {
                    Text("Bizi Değerlendir")
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
                row("Yardım & Destek", trailingIcon: "envelope.fill")
            }
            .buttonStyle(.plain)
        }
    }

    private var notificationsCard: some View {
        HStack(spacing: 12) {
            Text("Bildirimler")
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
