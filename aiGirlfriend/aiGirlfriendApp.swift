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
    @Environment(\.scenePhase) private var scenePhase
    @State private var notificationDelegate: NotificationDelegate?

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.isAuthenticated && store.isLoaded {
                    MainTabView()
                } else {
                    SplashView()
                }
            }
            .environment(navigationCenter)
            .environment(auth)
            .environment(store)
            .preferredColorScheme(.dark)
            .task {
                PurchaseService.shared.configure()
                let delegate = NotificationDelegate(store: store)
                notificationDelegate = delegate
                UNUserNotificationCenter.current().delegate = delegate
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                NotificationScheduler.shared.onForeground(characters: store.characters)
            case .background:
                NotificationScheduler.shared.onBackground(characters: store.characters)
            default:
                break
            }
        }
    }
}
