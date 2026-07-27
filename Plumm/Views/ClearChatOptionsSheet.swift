//
//  ClearChatOptionsSheet.swift
//  "Clear Chat" öncesi ne saklanacağını seçme ekranı — ChatView'in dişli
//  menüsünden açılır (bkz. ChatView.headerButton). Mesajlar/özet HER ZAMAN
//  silinir; burada sadece relationship_level/level_progress, memories ve
//  conversation_behaviors için "koru" seçilebilir (bkz. chat/index.ts clear
//  branch, ChatViewModel.clearChat).
//

import SwiftUI

struct ClearChatOptionsSheet: View {
    let character: Character
    let onConfirm: (_ keepLevel: Bool, _ keepMemories: Bool, _ keepBehaviors: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var keepLevel = false
    @State private var keepMemories = false
    @State private var keepBehaviors = false
    @State private var contentHeight: CGFloat = 320

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                AppColor.bg.ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("This clears your message history with \(character.name). Choose what to keep:")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 0) {
                        Toggle("Keep relationship level & progress", isOn: $keepLevel)
                            .padding(.vertical, 10)
                        Divider().overlay(.white.opacity(0.1))
                        Toggle("Keep memories", isOn: $keepMemories)
                            .padding(.vertical, 10)
                        Divider().overlay(.white.opacity(0.1))
                        Toggle("Keep behavior preferences", isOn: $keepBehaviors)
                            .padding(.vertical, 10)
                    }
                    .padding(.horizontal, 12)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    .toggleStyle(SwitchToggleStyle(tint: AppColor.pink))
                    .foregroundStyle(.white)

                    Button(role: .destructive) {
                        onConfirm(keepLevel, keepMemories, keepBehaviors)
                        dismiss()
                    } label: {
                        Text("Clear Chat").font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 50)
                            .background(LinearGradient(colors: [AppColor.pink, AppColor.amber],
                                                       startPoint: .leading, endPoint: .trailing), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { contentHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, h in contentHeight = h }
                    }
                )
            }
            .navigationTitle("Clear Chat")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.height(contentHeight + 56)])
        .presentationDragIndicator(.visible)
    }
}
