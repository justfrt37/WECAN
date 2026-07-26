//
//  LegalDocumentView.swift
//  Gizlilik Politikası / Kullanım Koşulları ekranı — metin LegalDocument'ten
//  gelir, burası sadece render eder. Uygulama içinde gösterilir (dış tarayıcıya
//  atmayız: App Review linkin ÇALIŞTIĞINI görmek ister, ağ/host sorunundan
//  etkilenmesin).
//

import SwiftUI

struct LegalDocumentView: View {
    let document: LegalDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    ForEach(document.sections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.heading)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                            ForEach(section.blocks) { block in
                                blockView(block)
                            }
                        }
                    }
                    Text("© \(currentYear) Plumm. All rights reserved.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 6)
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .background(
                LinearGradient(colors: [AppColor.bg, AppColor.bg2, AppColor.bg],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .toolbarBackground(AppColor.bg, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(document.title)
                .font(.system(size: 28, weight: .heavy))
                .foregroundStyle(.white)
            Text("Last updated: \(document.updated)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Text(document.intro)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func blockView(_ block: LegalBlock) -> some View {
        switch block {
        case .p(let text):
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 9) {
                        Circle()
                            .fill(AppColor.pink)
                            .frame(width: 5, height: 5)
                            .padding(.top, 7)
                        Text(item)
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var currentYear: String {
        String(Calendar.current.component(.year, from: Date()))
    }
}

#Preview("Privacy") { LegalDocumentView(document: .privacy) }
#Preview("Terms") { LegalDocumentView(document: .terms) }
