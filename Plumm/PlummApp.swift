//
//  PlummApp.swift
//  Plumm
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
struct PlummApp: App {
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
                    if onboarding.isCompleted
                        || ReviewModeService.shared.isEnabled
                        || onboarding.pendingChatCharacterName != nil {
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
                EventLogger.shared.startNewSession()
                EventLogger.shared.log("app_launch")
                // Satın alma sonrası sunucudan dönen bakiyeyi anında yazabilmek
                // için (TokenStore singleton değil, environment'tan geliyor).
                PurchaseService.shared.tokenStore = tokenStore
                PurchaseService.shared.configure()
                // Ürün→token eşlemesi artık sunucudan geliyor (PlummCatalog
                // kaldırıldı) — paywall'daki sayılar için erken çekilmeli.
                await CatalogService.shared.refresh()
                let delegate = NotificationDelegate(store: store)
                notificationDelegate = delegate
                UNUserNotificationCenter.current().delegate = delegate
                // Uygulama bildirime dokunulmadan (ör. ana ekran ikonuyla) açılmış
                // olabilir — zaten teslim edilmiş bildirimlerin mesajını işle.
                delegate.catchUpOnDeliveredNotifications()
                await tokenStore.refresh()
                // Sunucudaki abonelik tier'ını yükle → açılışta isPro DOĞRU olsun
                // (restore'a basmadan pro görünür; Pro butonu yerine token gösterilir).
                await PurchaseService.shared.refreshServerTier()
                // Açılışta kullanıcının kimlik + hak durumunun tek satırlık
                // özeti. refreshServerTier'dan SONRA çağrılıyor ki tier'ı
                // yazan iki kaynak da (RC entitlement + sunucu satırı) çalışmış
                // olsun, yani log NİHAİ durumu göstersin.
                PurchaseService.shared.logEntitlementState("launch")
                ImageCache.shared.evictIfNeeded()
                PlummTips.configureIfEligible(onboardingCompleted: onboarding.isCompleted)
            }
        }
        .onChange(of: onboarding.isCompleted) { _, done in
            // User finished onboarding this session — arm tips without a relaunch.
            PlummTips.configureIfEligible(onboardingCompleted: done)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // Soğuk açılıştaki İLK .active geçişi zaten .task'ta bir kez
                // damgalanıyor (app_launch + startNewSession) — burası arka
                // plandan DÖNÜŞLERİ de kapsıyor, bu yüzden her .active'de
                // yeniden çağırmak zararsız (yeni sessionId = yeni "ziyaret").
                EventLogger.shared.startNewSession()
                EventLogger.shared.log("app_foreground")
                NotificationScheduler.shared.onForeground(characters: store.characters)
                notificationDelegate?.catchUpOnDeliveredNotifications()
                // Picks up newly-added characters (DEV curated creations, etc.)
                // without requiring a reinstall — bkz. CharacterStore.refreshCharacters.
                Task { await store.refreshCharacters() }
                ImageCache.shared.evictIfNeeded()
            case .background:
                EventLogger.shared.log("app_background")
                EventLogger.shared.flush()
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
