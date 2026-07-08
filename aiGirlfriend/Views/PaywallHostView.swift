//
//  PaywallHostView.swift
//  Her `showPaywall = true` çağrısının açtığı sheet içeriği — artık gerçek
//  token/abonelik sayfası (bkz. TokenStoreView), eski RevenueCatUI/"coming
//  soon" yer tutucusu değil. Çağıran kod hiç değişmedi (isim aynı kaldı).
//

import SwiftUI

struct PaywallHostView: View {
    var body: some View {
        TokenStoreView()
    }
}
