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
    /// Pro+/Max only (bkz. ChatView gear menu entitlement check before
    /// opening this sheet, set-nickname edge function). `.characterNickname`
    /// is purely cosmetic display; `.userNickname` flows into chat/index.ts's
    /// system prompt.
    case characterNickname
    case userNickname

    var id: String { rawValue }

    /// `.characterNickname` needs the character's name in the title (see
    /// `AddCharacterNoteSheet.navTitle`, which special-cases it) — this
    /// generic title is only used as its fallback / for the other kinds.
    var title: String {
        switch self {
        case .memory: return String(localized: "Add Memory")
        case .behavior: return String(localized: "Add Behavior")
        case .characterNickname: return String(localized: "Rename")
        case .userNickname: return String(localized: "Nickname for You")
        }
    }
}

struct AddCharacterNoteSheet: View {
    let character: Character
    let kind: NoteKind
    /// Only meaningful for `.characterNickname`/`.userNickname` — the
    /// currently-set nickname, so the sheet opens pre-filled for editing
    /// (Add Memory/Add Behavior are additive lists, don't need this).
    var initialText: String = ""

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
                        switch kind {
                        case .memory: Text("\(character.name) should remember this:")
                        case .behavior: Text("\(character.name) should behave like this:")
                        case .characterNickname: Text("What should we call \(character.name) instead?")
                        case .userNickname: Text("What should \(character.name) call you?")
                        }
                    }
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextField("", text: $text, prompt: promptText.foregroundColor(.white.opacity(0.4)), axis: .vertical)
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
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
        // Ölçülen içerik + inline nav bar payı (~56) kadar yükseklik.
        .presentationDetents([.height(contentHeight + 56)])
        .presentationDragIndicator(.visible)
        .onAppear { text = initialText }
    }

    private var navTitle: String {
        kind == .characterNickname ? String(localized: "Rename \(character.name)") : kind.title
    }

    private var promptText: Text {
        switch kind {
        case .memory: return Text("e.g. my birthday is May 5th")
        case .behavior: return Text("e.g. always call me 'babe'")
        case .characterNickname: return Text("e.g. Boo")
        case .userNickname: return Text("e.g. Boo")
        }
    }

    /// Rejections (Grok injection detection, or Pro+/Max entitlement for the
    /// nickname kinds) or network errors are swallowed silently — the sheet
    /// is already dismissed by then (product decision, matches Add Memory/
    /// Add Behavior — the gear menu already checked entitlement before
    /// offering this sheet at all, so a 403 here is a rare stale-cache edge
    /// case, not a normal path worth surfacing).
    private func save() {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let characterId = character.id
        switch kind {
        case .memory, .behavior:
            // Additive lists — an empty save is a no-op, nothing to clear.
            if !content.isEmpty {
                let apiKind = kind == .memory ? "memory" : "behavior"
                EventLogger.shared.log("feature_used", ["feature": kind == .memory ? "memory_add" : "behavior_add"])
                Task { _ = try? await service.addCharacterNote(characterId: characterId, kind: apiKind, content: content) }
            }
        case .characterNickname, .userNickname:
            // Single field — an empty save CLEARS the nickname (bkz.
            // set-nickname edge function), so always send, even empty.
            // Bellek-içi anlık güncelleme — chat header/list ağ cevabını
            // beklemeden yeni ismi göstersin (bkz. injectProactive'deki aynı desen).
            if var stored = LocalConversationStore.shared.load(for: characterId) {
                if kind == .characterNickname { stored.characterNickname = content.isEmpty ? nil : content }
                else { stored.userNickname = content.isEmpty ? nil : content }
                LocalConversationStore.shared.save(stored, for: characterId)
            }
            let apiKind = kind == .characterNickname ? "character" : "user"
            EventLogger.shared.log("feature_used", ["feature": kind == .characterNickname ? "nickname_character" : "nickname_user"])
            Task { _ = try? await service.setNickname(characterId: characterId, kind: apiKind, content: content) }
        }
        dismiss()
    }
}
