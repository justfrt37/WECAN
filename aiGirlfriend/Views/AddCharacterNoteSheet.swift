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
        case .memory: return "Add Memory"
        case .behavior: return "Add Behavior"
        }
    }
}

struct AddCharacterNoteSheet: View {
    let character: Character
    let kind: NoteKind

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    private let service = ChatService()

    var body: some View {
        NavigationStack {
            ZStack {
                AppColor.bg.ignoresSafeArea()
                VStack(spacing: 16) {
                    Text(kind == .memory
                         ? "\(character.name) should remember this:"
                         : "\(character.name) should behave like this:")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextField("", text: $text,
                              prompt: Text(kind == .memory ? "e.g. my birthday is May 5th" : "e.g. always call me 'babe'")
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
                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
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
