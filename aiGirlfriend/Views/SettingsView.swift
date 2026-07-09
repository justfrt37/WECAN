//
//  SettingsView.swift
//  "Ayarlar" sayfası — Profil'den açılır.
//  Tasarım: AIGUI .pen "Ayarlar (Plumm)".
//

import SwiftUI
import StoreKit
import UIKit
import UserNotifications

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview
    @Environment(\.openURL) private var openURL

    @State private var appLock = UserDefaults.standard.bool(forKey: "settings.appLock")
    @State private var notificationsOn = false
    @State private var showHelp = false
    @State private var showDeleteConfirm = false

    // TODO: gerçek URL'lerle değiştir (App Store / gizlilik / koşullar).
    private let shareURL = URL(string: "https://apps.apple.com/app/id0000000000")!
    private let privacyURL = URL(string: "https://plumm.app/privacy")!
    private let termsURL = URL(string: "https://plumm.app/terms")!

    private let cardRadius: CGFloat = 18

    var body: some View {
        ZStack {
            LinearGradient(colors: [AppColor.bg2, AppColor.bg, Color(hex: 0x100710)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    topBar
                    notificationsCard
                    lockCard
                    ShareLink(item: shareURL) {
                        row("Arkadaşına Öner", trailingIcon: "square.and.arrow.up")
                    }
                    .buttonStyle(.plain)
                    Button { requestReview() } label: {
                        row("Bizi Değerlendir", trailingIcon: "heart.fill", trailingTint: Color(hex: 0xFF5A6A))
                    }
                    .buttonStyle(.plain)
                    Button { showHelp = true } label: { row("Yardım & Destek") }
                        .buttonStyle(.plain)
                    Button { openURL(privacyURL) } label: { row("Gizlilik Politikası") }
                        .buttonStyle(.plain)
                    Button { openURL(termsURL) } label: { row("Kullanım Koşulları") }
                        .buttonStyle(.plain)
                    deleteRow
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { notificationsOn = await currentNotificationStatus() }
        .sheet(isPresented: $showHelp) { HelpSupportView() }
        .alert("Tüm verileri sil?", isPresented: $showDeleteConfirm) {
            Button("İptal", role: .cancel) {}
            Button("Sil", role: .destructive) { deleteAllData() }
        } message: {
            Text("Tüm sohbetlerin ve verilerin kalıcı olarak silinecek. Bu işlem geri alınamaz.")
        }
    }

    // MARK: Üst bar

    private var topBar: some View {
        HStack(spacing: 16) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.08), in: Circle())
            }
            Text("Ayarlar")
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.bottom, 4)
    }

    // MARK: Bildirimler kartı (Profil'den buraya taşındı)

    private var notificationsCard: some View {
        HStack(spacing: 12) {
            Text("Bildirimler")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
            Toggle("", isOn: $notificationsOn)
                .labelsHidden()
                .tint(AppColor.pink)
                .onChange(of: notificationsOn) { _, wantsOn in
                    Task { await handleNotificationToggle(wantsOn) }
                }
            NavigationLink { NotificationSettingsView() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 20)
        .frame(height: 66)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: cardRadius))
        .overlay(RoundedRectangle(cornerRadius: cardRadius).strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }

    // MARK: Uygulama kilidi kartı

    private var lockCard: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Uygulama Kilidi")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                Text("Face ID veya parmak izi ile uygulamayı kilitle")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $appLock)
                .labelsHidden()
                .tint(AppColor.pink)
                .onChange(of: appLock) { _, v in
                    UserDefaults.standard.set(v, forKey: "settings.appLock")
                }
        }
        .padding(18)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }

    // MARK: Satır

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

    private var deleteRow: some View {
        Button { showDeleteConfirm = true } label: {
            HStack {
                Text("Tüm Verileri Sil")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(hex: 0xFF5A6A))
                Spacer()
                Image(systemName: "trash.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(hex: 0xFF5A6A))
            }
            .padding(.horizontal, 20)
            .frame(height: 66)
            .background(Color(hex: 0xFF4D5E).opacity(0.08), in: RoundedRectangle(cornerRadius: cardRadius))
            .overlay(RoundedRectangle(cornerRadius: cardRadius).strokeBorder(Color(hex: 0xFF4D5E).opacity(0.28), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Aksiyonlar

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

    private func deleteAllData() {
        // Yerel konuşmalar + sohbet listesi önbelleği + akış bayrakları.
        LocalConversationStore.shared.clearAll()
        let cache = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chatlist_cache.json")
        try? FileManager.default.removeItem(at: cache)
        dismiss()
    }
}

#Preview {
    NavigationStack { SettingsView() }
}
