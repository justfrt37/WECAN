//
//  ProfileView.swift
//  "Profil" sekmesi.
//  Not: Uygulama sadece anonim girişle çalışıyor (kullanıcı adı/e-posta/katılım
//  tarihi gibi gerçek bir kimlik verisi yok) — bu yüzden kimlik bölümü minimal
//  tutuldu, uydurma isim/istatistik gösterilmiyor.
//

import SwiftUI
import UIKit
import UserNotifications

struct ProfileView: View {
    @State private var notificationsOn = false
    @State private var showPaywall = false
    @State private var showHelp = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 18) {
                    avatarCard
                    proBanner
                    settingsMenu
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
        .sheet(isPresented: $showPaywall) { PaywallHostView() }
        .sheet(isPresented: $showHelp) { HelpSupportView() }
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
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Color(hex: 0x2E1E14), Color(hex: 0x3D2A1A)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: PRO banner (RevenueCat iskeleti — bkz. PurchaseService)

    private var proBanner: some View {
        Button { showPaywall = true } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "crown.fill").font(.system(size: 14))
                        Text("Lumi PRO").font(.system(size: 16, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    Text("Unlimited chat, voice messages, and exclusive characters")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Text("Upgrade")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(hex: 0xFF6F61))
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(.white, in: RoundedRectangle(cornerRadius: 18))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(
                LinearGradient(colors: [Color(hex: 0xFFA726), Color(hex: 0xFF6F61)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 20)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Ayarlar menüsü

    private var settingsMenu: some View {
        VStack(spacing: 0) {
            notificationRow
            divider
            Button { showHelp = true } label: { menuRow("questionmark.circle.fill", "Help & Support", tint: Color(hex: 0x5B8DEF)) }
        }
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
    }

    private func menuRow(_ icon: String, _ title: LocalizedStringKey, tint: Color) -> some View {
        HStack(spacing: 14) {
            rowIcon(icon, tint: tint)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .contentShape(Rectangle())
    }

    private var notificationRow: some View {
        HStack(spacing: 14) {
            rowIcon("bell.fill", tint: AppColor.amber)
            Text("Notifications")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
            Toggle("", isOn: $notificationsOn)
                .labelsHidden()
                .tint(AppColor.pink)
                .onChange(of: notificationsOn) { _, wantsOn in
                    Task { await handleNotificationToggle(wantsOn) }
                }
            // Master toggle stays independently tappable; this chevron is the only
            // navigation trigger to the per-bot cap menu (see NotificationSettingsView).
            NavigationLink {
                NotificationSettingsView()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    private func rowIcon(_ icon: String, tint: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Bildirim izni

    private func currentNotificationStatus() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
    }

    /// Açmaya çalışırsa gerçek iOS izni ister; kapatmaya çalışırsa (iOS uygulama
    /// içinden izni geri alamadığı için) Ayarlar'a yönlendirir.
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
