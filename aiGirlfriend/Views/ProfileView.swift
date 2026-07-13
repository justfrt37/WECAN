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
    @Environment(TokenStore.self) private var tokenStore
    @State private var showPaywall = false
    @State private var devTier: SubscriptionTier = PurchaseService.shared.tier
    @State private var showDevCreateCharacter = false
    @State private var showDevEditCharacter = false
    #if DEBUG
    @State private var dbgSettings = ProcessInfo.processInfo.environment["PROFILE_ROUTE"] == "settings"
    #endif

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 18) {
                    avatarCard
                    proBanner
                    settingsMenu
                    // DEV-only, gated to the two dev uids (bkz. DevAccess) —
                    // was shown to EVERYONE before (no gating existed).
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
        .sheet(isPresented: $showPaywall) { PaywallHostView() }
        .sheet(isPresented: $showHelp) { HelpSupportView() }
        // CharacterStore is already injected ambiently at MainTabView's root —
        // no need to re-inject it here, same as every other CreateCharacterView call site.
        .sheet(isPresented: $showDevCreateCharacter) { CreateCharacterView(devMode: .create) }
        .sheet(isPresented: $showDevEditCharacter) { DevEditCharacterPickerView() }
        .task { notificationsOn = await currentNotificationStatus() }
        #if DEBUG
        .sheet(isPresented: $dbgSettings) { NavigationStack { SettingsView() } }
        #endif
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
            // TEMP TESTING (2026-07-12) — shows the Supabase auth UID so it
            // can be cross-checked against DB rows while testing. Tap to
            // copy. REVERT/remove once testing is done.
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

    // MARK: PRO banner (RevenueCat iskeleti — bkz. PurchaseService)

    @ViewBuilder
    private var proBanner: some View {
        if PurchaseService.shared.isPro {
            activeSubscriptionBanner
        } else {
            goProBanner
        }
    }

    private var activeSubscriptionBanner: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "crown.fill").font(.system(size: 14))
                Text("You are \(PurchaseService.shared.tier.displayName)!")
                    .font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            LinearGradient(colors: [Color(hex: 0xFFA726), Color(hex: 0xFF6F61)],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 20)
        )
    }

    private var goProBanner: some View {
        Button { showPaywall = true } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "crown.fill").font(.system(size: 14))
                        Text("Plumm PRO").font(.system(size: 16, weight: .bold))
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
            NavigationLink { SettingsView() } label: { menuRow("gearshape.fill", "Settings", tint: Color(hex: 0x8E8E93)) }
        }
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }


    /// GEÇİCİ DEV PANELİ — RevenueCat/gerçek IAP kurulunca KALDIRILACAK (bkz.
    /// DevTokenTools, dev-token-tools edge function). Token mekaniklerini
    /// (harcama/kazanma, abonelik tier'ları) gerçek ödeme olmadan test etmeye
    /// yarıyor — tier butonları GERÇEK bir ilk-kez-abone-olma gibi davranır:
    /// hem `subscriptions` satırını hem o haftalık token miktarını basar.
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

    /// DEV-only — opens CreateCharacterView's dev mode (bkz.
    /// CreateCharacterView.DevWizardMode, dev-create-character/
    /// dev-update-character edge functions). Unlike devTokenTestPanel this
    /// doesn't get deleted with RevenueCat; it stays as a permanent dev
    /// tool, but only ever visible to the two dev uids.
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

    private func rowIcon(_ icon: String, tint: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    ProfileView()
}
