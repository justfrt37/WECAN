//
//  AddCharacterNoteSheet.swift
//  "Add Memory" / "Add Behavior" — shared entry sheet opened from ChatView's
//  gear menu and ChatListView's long-press menu. Only needs
//  ChatService.addCharacterNote, not a full ChatViewModel.
//

import SwiftUI

enum NoteKind: String, Identifiable {
    case memory
    case behavior

    var id: String { rawValue }

    var title: String {
        switch self {
        case .memory: return String(localized: "Add Memory")
        case .behavior: return String(localized: "Add Behavior")
        }
    }
}

struct AddCharacterNoteSheet: View {
    let character: Character
    let kind: NoteKind

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    /// Sheet, sabit .medium yerine İÇERİĞİNE göre boyutlanır — ölçülen içerik
    /// yüksekliği + nav bar payı (bkz. kullanıcı talebi: aşağıda büyük boşluk kalmasın).
    @State private var contentHeight: CGFloat = 220
    private let service = ChatService()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                AppColor.bg.ignoresSafeArea()
                VStack(spacing: 16) {
                    Group {
                        if kind == .memory {
                            Text("\(character.name) should remember this:")
                        } else {
                            Text("\(character.name) should behave like this:")
                        }
                    }
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextField("", text: $text,
                              prompt: (kind == .memory
                                        ? Text("e.g. my birthday is May 5th")
                                        : Text("e.g. always call me 'babe'"))
                                .foregroundColor(.white.opacity(0.4)), axis: .vertical)
                        .lineLimit(3...6)
                        .foregroundStyle(.white).tint(AppColor.pink)
                        .padding(12)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    Button {
                        save()
                    } label: {
                        Text("Save").font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 50)
                            .background(LinearGradient(colors: [AppColor.pink, AppColor.amber],
                                                       startPoint: .leading, endPoint: .trailing), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                // Yukarıdan/aşağıdan ferah, eşit boşluk; Spacer YOK (yoksa sheet'i
                // doldurup altta büyük boşluk bırakıyordu).
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                // İçeriğin doğal yüksekliğini ölç → detent buna göre.
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { contentHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, h in contentHeight = h }
                    }
                )
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        // Ölçülen içerik + inline nav bar payı (~56) kadar yükseklik.
        .presentationDetents([.height(contentHeight + 56)])
        .presentationDragIndicator(.visible)
    }

    /// Rejections (Grok injection detection) or network errors are swallowed
    /// silently — the sheet is already dismissed by then (product decision).
    private func save() {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty {
            let apiKind = kind == .memory ? "memory" : "behavior"
            let characterId = character.id
            Task {
                _ = try? await service.addCharacterNote(characterId: characterId, kind: apiKind, content: content)
            }
        }
        dismiss()
    }
}
