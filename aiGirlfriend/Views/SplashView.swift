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
            LinearGradient(
                colors: [AppColor.bg, AppColor.bg2, AppColor.bg],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "heart.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(AppColor.pink)

                Text("aiGirlfriend")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)

                if auth.failed {
                    Text("Giriş yapılamadı.\nİnternet bağlantını kontrol et.")
                        .multilineTextAlignment(.center)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))

                    Button {
                        Task { await loadAll() }
                    } label: {
                        Text("Tekrar dene")
                            .font(.headline)
                            .foregroundStyle(Color(hex: 0x0F0518))
                            .padding(.horizontal, 28)
                            .padding(.vertical, 12)
                            .background(.white, in: Capsule())
                    }
                } else {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.3)
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
