//
//  SplashView.swift
//  Açılış ekranı: anonim giriş + karakter kataloğu yüklenirken gösterilir.
//  Başarısız olursa "Tekrar dene" butonu (ağ sorunları için).
//

import SwiftUI

struct SplashView: View {
    @Environment(AuthService.self) private var auth
    @Environment(CharacterStore.self) private var store

    var body: some View {
        ZStack {
            OBTheme.bg.ignoresSafeArea()

            // Ortada "❤ Plumm" logosu (Pencil splash mockup'ı).
            OBBrandMark(size: 30)

            // Yükleme / hata durumu altta, sabit — logoyu ortada tutar.
            VStack {
                Spacer()
                if auth.failed {
                    VStack(spacing: 16) {
                        Text("Login failed.\nCheck your internet connection.")
                            .multilineTextAlignment(.center)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.9))

                        Button {
                            Task { await loadAll() }
                        } label: {
                            Text("Try again")
                                .font(.headline)
                                .foregroundStyle(OBTheme.bg)
                                .padding(.horizontal, 28)
                                .padding(.vertical, 12)
                                .background(.white, in: Capsule())
                        }
                    }
                    .padding(.bottom, 60)
                } else {
                    ProgressView()
                        .tint(.white.opacity(0.7))
                        .padding(.bottom, 72)
                }
            }
        }
        .task {
            await loadAll()
        }
    }

    /// Önce anonim giriş, başarılıysa karakterleri çek.
    private func loadAll() async {
        await auth.bootstrap()
        if auth.isAuthenticated {
            await store.load()
        }
    }
}

#Preview {
    SplashView()
        .environment(AuthService())
        .environment(CharacterStore())
}
