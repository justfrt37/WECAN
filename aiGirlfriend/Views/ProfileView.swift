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

    // DEV
    @State private var devTier: SubscriptionTier = PurchaseService.shared.tier
    @State private var showDevCreateCharacter = false
    @State private var showDevEditCharacter = false

    // Ayarlar (eski SettingsView'den buraya taşındı)
    @State private var appLock = UserDefaults.standard.bool(forKey: "settings.appLock")
    @State private var notificationsOn = false
    @State private var showDeleteConfirm = false

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
                    // DEV-only, gated to the two dev uids (bkz. DevAccess).
                    if DevAccess.isDev {
                        devTokenTestPanel
                        devCuratedCharacterPanel
                    }
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
        .sheet(isPresented: $showDevCreateCharacter) { CreateCharacterView(devMode: .create) }
        .sheet(isPresented: $showDevEditCharacter) { DevEditCharacterPickerView() }
        .task { notificationsOn = await currentNotificationStatus() }
        .alert("Tüm verileri sil?", isPresented: $showDeleteConfirm) {
            Button("İptal", role: .cancel) {}
            Button("Sil", role: .destructive) { deleteAllData() }
        } message: {
            Text("Tüm sohbetlerin ve verilerin kalıcı olarak silinecek. Bu işlem geri alınamaz.")
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
            lockCard

            ShareLink(item: shareURL) {
                row("Arkadaşına Öner", trailingIcon: "square.and.arrow.up")
            }
            .buttonStyle(.plain)

            Button { requestReview() } label: {
                row("Bizi Değerlendir", trailingIcon: "heart.fill", trailingTint: Color(hex: 0xFF5A6A))
            }
            .buttonStyle(.plain)

            Button { openURL(supportMailURL) } label: {
                row("Yardım & Destek", trailingIcon: "envelope.fill")
            }
            .buttonStyle(.plain)

            deleteRow
        }
    }

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

    private func deleteAllData() {
        // Yerel konuşmalar + sohbet listesi önbelleği.
        LocalConversationStore.shared.clearAll()
        let cache = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chatlist_cache.json")
        try? FileManager.default.removeItem(at: cache)
    }

    // MARK: DEV panelleri

    /// GEÇİCİ DEV PANELİ — RevenueCat/gerçek IAP kurulunca KALDIRILACAK (bkz.
    /// DevTokenTools). Token mekaniklerini gerçek ödeme olmadan test etmeye
    /// yarıyor.
    private var devTokenTestPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "hammer.fill").foregroundStyle(Color(hex: 0x9B59B6))
                Text("DEV: Token Testing")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }

            HStack(spacing: 10) {
                devActionButton("+1000 🪙") { await DevTokenTools.addTokens(into: tokenStore) }
                devActionButton("-1000 🪙") { await DevTokenTools.removeTokens(from: tokenStore) }
            }

            Text("Subscription tier")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))

            Picker("", selection: $devTier) {
                Text("Off").tag(SubscriptionTier.none)
                Text("Pro").tag(SubscriptionTier.pro)
                Text("Pro+").tag(SubscriptionTier.proPlus)
                Text("Max").tag(SubscriptionTier.max)
            }
            .pickerStyle(.segmented)
            .onChange(of: devTier) { _, newTier in
                Task { await DevTokenTools.setTier(newTier, tokenStore: tokenStore) }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    /// DEV-only — CreateCharacterView'un dev modunu açar (kalıcı dev aracı,
    /// yalnızca iki dev uid'e görünür).
    private var devCuratedCharacterPanel: some View {
        VStack(spacing: 10) {
            devCuratedCharacterRow(icon: "wand.and.stars", title: "DEV: Create Curated Character") {
                showDevCreateCharacter = true
            }
            devCuratedCharacterRow(icon: "pencil.and.list.clipboard", title: "DEV: Edit Existing Character") {
                showDevEditCharacter = true
            }
        }
    }

    private func devCuratedCharacterRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Color(hex: 0x9B59B6))
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(16)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func devActionButton(_ title: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(AppColor.pink.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ProfileView()
}
