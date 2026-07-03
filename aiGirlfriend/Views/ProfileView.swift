//
//  ProfileView.swift
//  "Profil" sekmesi — kullanıcı profili.
//  Tasarım: AIGUI .pen "Profile" ekranı. (Şimdilik dummy/statik veriler.)
//

import SwiftUI

struct ProfileView: View {
    @State private var notificationsOn = true

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 18) {
                    profileCard
                    statsRow
                    proBanner
                    settingsMenu
                    logoutButton
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
    }

    // MARK: Başlık

    private var header: some View {
        HStack {
            Text("Profil")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            Image(systemName: "gearshape.fill")
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.08), in: Circle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: Profil kartı

    private var profileCard: some View {
        VStack(spacing: 12) {
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

            HStack(spacing: 8) {
                Text("Alex Morgan")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(AppColor.pink)
            }

            Text("@alexm  ·  joined Mar 2025")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
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

    // MARK: İstatistikler

    private var statsRow: some View {
        HStack(spacing: 10) {
            statCard("24", "Companions")
            statCard("1.2k", "Messages")
            statCard("38", "Day streak")
        }
    }

    private func statCard(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 74)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: PRO banner

    private var proBanner: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "crown.fill").font(.system(size: 14))
                    Text("Lumi PRO").font(.system(size: 16, weight: .bold))
                }
                .foregroundStyle(.white)
                Text("Sınırsız sohbet, sesli mesaj ve özel karakterler")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
            Text("Yükselt")
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

    // MARK: Ayarlar menüsü

    private var settingsMenu: some View {
        VStack(spacing: 0) {
            menuRow("person.crop.circle.fill", "Edit profile", tint: AppColor.pink)
            divider
            notificationRow
            divider
            menuRow("lock.fill", "Privacy & security", tint: Color(hex: 0x4ECDC4))
            divider
            menuRow("sparkles", "Personalization", tint: Color(hex: 0xFFA726))
            divider
            menuRow("questionmark.circle.fill", "Help & support", tint: Color(hex: 0x5B8DEF))
        }
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
    }

    private func menuRow(_ icon: String, _ title: String, tint: Color) -> some View {
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
    }

    private var notificationRow: some View {
        HStack(spacing: 14) {
            rowIcon("bell.fill", tint: AppColor.amber)
            Text("Bildirimler")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
            Toggle("", isOn: $notificationsOn)
                .labelsHidden()
                .tint(AppColor.pink)
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

    // MARK: Çıkış

    private var logoutButton: some View {
        Button { } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 14))
                Text("Çıkış Yap").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(AppColor.pink)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(AppColor.pink.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(AppColor.pink.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ProfileView()
}
