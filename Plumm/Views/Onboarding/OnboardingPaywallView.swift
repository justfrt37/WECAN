//
//  OnboardingPaywallView.swift
//  ONB6 — abonelik paywall'ı. "O bekliyor" ekranından sonra gelir.
//  Arka planda ONB3'te seçilen kızın videosu (bulanık) oynar — "kilidini aç"
//  fikrini pekiştirir. Pencil "PAYWALL" mockup'ının uygulama karşılığı.
//

import SwiftUI

struct OnboardingPaywallView: View {
    @Environment(OnboardingStore.self) private var onboarding
    @Environment(\.dismiss) private var dismiss

    /// X (kapat) butonu 2 sn sonra belirir — kullanıcı önce paywall'ı görsün.
    @State private var showClose = false

    /// Yasal metinler UYGULAMA İÇİNDE açılır (dış tarayıcı/host'a bağımlı değil,
    /// bkz. LegalDocumentView) — App Review linklerin çalıştığını görmeli.
    @State private var legalDocument: LegalDocument?

    /// Kapatma: bir cover olarak (PRO butonundan) açıldıysa dismiss() yeter.
    /// Onboarding'in son adımı olarak açıldıysa (isCompleted henüz false) —
    /// ONB3'te seçilen kızın chat'ine girilir; onboarding TAM DA chat görününce
    /// complete olur (bkz. MainTabView.openPendingOnboardingChat). Seçim yoksa
    /// doğrudan tamamla.
    private func close() {
        dismiss()
        if !onboarding.isCompleted, let name = onboarding.selectedCharacter?.chatCharacterName {
            onboarding.pendingChatCharacterName = name
        } else {
            onboarding.complete()
        }
    }

    /// RevenueCat paketleri (ucuzdan pahalıya) buradan gelir; seçili paket id'si.
    /// Varsayılan seçim en pahalı (en avantajlı) paket — `packages.last`.
    @Environment(TokenStore.self) private var tokenStore
    @State private var purchases = PurchaseService.shared
    @State private var selectedPackageID: String?
    @State private var isPurchasing = false

    private var packages: [PaywallPackage] { purchases.packages }
    private var selectedPackage: PaywallPackage? {
        packages.first { $0.id == selectedPackageID } ?? packages.last
    }
    /// En pahalı paketin haftalık eşdeğerine göre tasarruf yüzdesi ("80% OFF").
    private func savingsBadge(for pkg: PaywallPackage) -> String {
        let maxPerWeek = packages.compactMap(\.perWeekValue).max()
        if let mine = pkg.perWeekValue, let top = maxPerWeek, top > 0, mine < top {
            let pct = ((1 - mine / top) as NSDecimalNumber).doubleValue * 100
            return String(format: "%d%% OFF", Int(pct.rounded()))
        }
        return "Best Value"
    }

    /// Arkada oynayacak video — ONB3'te seçilen kızınki (yoksa varsayılan).
    private var bgVideo: String {
        onboarding.selectedCharacter?.selectedVideo ?? "onb4Video"
    }

    private let features: [String] = [
        "Voice conversations",
        "Unlimited photos",
        "Create your own girl",
        "Unlimited access (24/7)",
        "Long-term memory",
    ]

    var body: some View {
        ZStack {
            // Seçilen kızın videosu — bulanık + karartma ("kilidini aç" hissi).
            LoopingVideoPlayer(resourceName: bgVideo)
                .id(bgVideo)
                .ignoresSafeArea()
                .blur(radius: 6)
                .overlay(scrim.ignoresSafeArea())

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                content
            }

            // Satın alma / geri yükleme sürerken: düşük-opacity siyah gradient +
            // ortada dönen loading. İşlem cevabı gelince kalkar.
            if isPurchasing {
                LinearGradient(
                    colors: [.black.opacity(0.35), .black.opacity(0.55)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
                .overlay {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isPurchasing)
        .task {
            if packages.isEmpty { await purchases.loadOfferings() }
        }
        .task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeIn(duration: 0.4)) { showClose = true }
        }
        .sheet(item: $legalDocument) { LegalDocumentView(document: $0) }
    }

    // MARK: Üst bar (X + logo PRO)

    private var topBar: some View {
        ZStack {
            OBBrandMarkPro()
            HStack {
                Button { close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 30, height: 30)
                }
                .opacity(showClose ? 1 : 0)
                .disabled(!showClose)
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    // MARK: Alt içerik

    private var content: some View {
        VStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(features, id: \.self) { f in
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color(hex: 0x34D399))
                        Text(f)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 30)

            if packages.isEmpty {
                ProgressView()
                    .tint(.white)
                    .frame(height: 96)
            } else {
                HStack(spacing: 14) {
                    // Ucuzdan pahalıya; en pahalıda (packages.last) tasarruf rozeti.
                    ForEach(packages) { pkg in
                        planCard(pkg, isTop: pkg.id == packages.last?.id)
                    }
                }
                .padding(.top, 10)   // üste taşan tasarruf rozetine yer
            }

            Button { unlock() } label: {
                Group {
                    if isPurchasing {
                        ProgressView().tint(.white)
                    } else {
                        Text("Continue").font(.system(size: 20, weight: .heavy))
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 62)
                .background(OBTheme.buttonGradient, in: RoundedRectangle(cornerRadius: 20))
            }
            .disabled(isPurchasing)

            legalRow
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)   // buton yere daha yakın olsun
    }

    private func planCard(_ pkg: PaywallPackage, isTop: Bool) -> some View {
        let selected = selectedPackage?.id == pkg.id
        // Alt satır: haftalık eşdeğer varsa onu, yoksa periyot etiketini göster.
        let sub = pkg.weeklyEquivalent ?? pkg.periodLabel ?? " "
        return Button { selectedPackageID = pkg.id } label: {
            // Her iki kart AYNI içerik (başlık/fiyat/alt) → eşit boy. Rozet
            // layout dışında, üste taşan overlay olarak durur (boyu etkilemez).
            VStack(spacing: 5) {
                Text(pkg.periodName).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(pkg.localizedPrice).font(.system(size: 22, weight: .heavy)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(sub).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18).padding(.horizontal, 8)
            .background(
                (selected ? OBTheme.coral.opacity(0.16) : Color.white.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: 20)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(selected ? OBTheme.coral : .white.opacity(0.18),
                                  lineWidth: selected ? 2.5 : 1.5)
            )
            .overlay(alignment: .top) {
                if isTop {
                    Text(savingsBadge(for: pkg))
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(OBTheme.buttonGradient, in: Capsule())
                        .offset(y: -11)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// "Kilidi Aç" — seçili paketi satın alır; başarılıysa onboarding'i kapatır.
    /// Paket yüklenmediyse (offering boş) akışı bloke etmemek için kapatır.
    private func unlock() {
        guard let pkg = selectedPackage else { close(); return }
        Task {
            isPurchasing = true
            let ok = await purchases.purchase(pkg)
            if ok { await tokenStore.refresh() }   // sunucu verdiği token'ları çek
            isPurchasing = false
            if ok { close() }
        }
    }

    /// Butonun altındaki yasal linkler — Privacy, Terms, Restore.
    private var legalRow: some View {
        HStack(spacing: 16) {
            Button("Privacy Policy") { legalDocument = .privacy }
            Button("Terms of Use") { legalDocument = .terms }
            Button("Restore") { restore() }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.5))
        .buttonStyle(.plain)
    }

    private func restore() {
        Task {
            isPurchasing = true
            let ok = await purchases.restore()
            if ok { await tokenStore.refresh() }
            isPurchasing = false
            if ok { close() }
        }
    }

    /// Video üstü karartma — metni okunur kılar.
    private var scrim: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(hex: 0x0E060A, alpha: 0.30), location: 0.0),
                .init(color: Color(hex: 0x0E060A, alpha: 0.35), location: 0.35),
                .init(color: Color(hex: 0x140810, alpha: 0.82), location: 0.60),
                .init(color: Color(hex: 0x0C0509, alpha: 0.97), location: 1.0),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }
}

/// "❤ Plumm PRO" logo satırı — normal OBBrandMark + PRO rozeti.
private struct OBBrandMarkPro: View {
    var body: some View {
        HStack(spacing: 8) {
            OBBrandMark(size: 22)
            Text("PRO")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(OBTheme.buttonGradient, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
