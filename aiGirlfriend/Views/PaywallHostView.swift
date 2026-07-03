//
//  PaywallHostView.swift
//  Her PRO butonunun açtığı sheet içeriği. RevenueCatUI paketi eklendiğinde
//  gerçek `PaywallView()` gösterilir; eklenmediyse basit bir yer tutucu.
//  Çağıran kod hiç değişmez — sadece paket eklenip apiKey doldurulur.
//

import SwiftUI
#if canImport(RevenueCatUI)
import RevenueCatUI
#endif

struct PaywallHostView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if canImport(RevenueCatUI)
        PaywallView(displayCloseButton: true)
        #else
        placeholder
        #endif
    }

    private var placeholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "crown.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color(hex: 0xFFA726))
            Text("Lumi PRO coming soon")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
            Text("The subscription system isn't set up yet.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Button("Close") { dismiss() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppColor.pink)
                .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.bg.ignoresSafeArea())
    }
}
