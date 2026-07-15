//
//  aiGirlfriendApp.swift
//  aiGirlfriend
//
//  AI companion / arkadaş uygulaması.
//  Backend: Supabase (DB + Auth + Edge Functions)
//  LLM: Grok 4.1 Fast (xAI) — API key SUNUCUDA, Edge Function üzerinden çağrılır.
//
//  Açılışta Supabase anonim giriş (AuthService, retry'lı) yapılır.
//  Navigasyon: Bible projesindeki NavigationCenter router pattern'i kullanılır.
//

import SwiftUI
import UserNotifications

@main
struct aiGirlfriendApp: App {
    @State private var navigationCenter = NavigationCenter()
    @State private var auth = AuthService()
    @State private var store = CharacterStore()
    @State private var tokenStore = TokenStore()
    @State private var onboarding = OnboardingStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var notificationDelegate: NotificationDelegate?

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.isAuthenticated && store.isLoaded {
                    // pendingChatCharacterName set ise (ONB5 bitti) MainTabView'e
                    // geç — onboarding TAM DA seçilen chat görününce complete olur
                    // (bkz. MainTabView.openPendingOnboardingChat).
                    if onboarding.isCompleted || onboarding.pendingChatCharacterName != nil {
                        MainTabView()
                    } else {
                        OnboardingFlowView()
                    }
                } else {
                    SplashView()
                }
            }
            .environment(navigationCenter)
            .environment(auth)
            .environment(store)
            .environment(tokenStore)
            .environment(onboarding)
            .preferredColorScheme(.dark)
            .task {
                PurchaseService.shared.configure()
                #if DEBUG
                // GEÇİCİ (test): kullanıcıyı PRO göster — SADECE debug derlemede,
                // release'e sızmaz. RevenueCat/backend-otoriter PRO kurulunca kaldır.
                PurchaseService.shared.tier = .pro
                #endif
                let delegate = NotificationDelegate(store: store)
                notificationDelegate = delegate
                UNUserNotificationCenter.current().delegate = delegate
                // Uygulama bildirime dokunulmadan (ör. ana ekran ikonuyla) açılmış
                // olabilir — zaten teslim edilmiş bildirimlerin mesajını işle.
                delegate.catchUpOnDeliveredNotifications()
                await tokenStore.refresh()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                NotificationScheduler.shared.onForeground(characters: store.characters)
                notificationDelegate?.catchUpOnDeliveredNotifications()
                // Picks up newly-added characters (DEV curated creations, etc.)
                // without requiring a reinstall — bkz. CharacterStore.refreshCharacters.
                Task { await store.refreshCharacters() }
            case .background:
                NotificationScheduler.shared.onBackground(characters: store.characters)
            default:
                break
            }
        }
        .onChange(of: store.isLoaded) { _, loaded in
            // Bir bildirime dokunma, karakterler yüklenmeden önce (soğuk başlangıçta)
            // gelmiş olabilir — o zaman ertelenmişti, burada tekrar oynatılır.
            if loaded { notificationDelegate?.replayPendingTapIfNeeded() }
        }
    }
}
