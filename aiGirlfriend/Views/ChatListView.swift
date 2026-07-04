//
//  ChatListView.swift
//  Chat sekmesi — "Chat History" tasarımı.
//  Başlık + arama + son mesajlı sohbet satırları (okunmamış rozeti + Yazıyor).
//

import SwiftUI

private struct ChatItem: Identifiable {
    let character: Character
    let conversationID: UUID
    let last: LastMessage?
    let unread: Int
    let updatedAt: String?
    var id: UUID { character.id }
}

struct ChatListView: View {
    @Environment(CharacterStore.self) private var store
    @State private var items: [ChatItem] = []
    @State private var isLoading = true
    @State private var searchText = ""

    private let service = ConversationsService()

    private var filtered: [ChatItem] {
        guard !searchText.isEmpty else { return items }
        return items.filter { $0.character.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [AppColor.bg, AppColor.bg2, AppColor.bg],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    searchBar
                    if isLoading {
                        ProgressView().tint(.white)
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    } else if items.isEmpty {
                        emptyState
                    } else {
                        messagesSection
                    }
                }
                .padding(.bottom, 100) // tab bar boşluğu
            }
        }
        .task { await load() }
        .onChange(of: store.typingCharacterIDs) { Task { await load() } }
    }

    private func load() async {
        async let convsT = service.fetchConversations()
        async let msgsT = service.fetchAllMessages()
        let (convs, msgs) = await (convsT, msgsT)

        // Mesajları konuşmaya göre grupla (desc sıralı geldi).
        var byConv: [UUID: [LastMessage]] = [:]
        for m in msgs { byConv[m.conversationID, default: []].append(m) }

        items = convs.compactMap { conv in
            guard let ch = store.characters.first(where: { $0.id == conv.characterID }) else { return nil }
            let convMsgs = byConv[conv.id] ?? []
            let localStored = LocalConversationStore.shared.load(for: conv.characterID)

            // Yerel depo VARSA baz alınır — sunucu hiçbir zaman görmediği bildirim
            // enjeksiyonlarını (jealousy/ghosted/liked) da içerir; `ReadTracker.seen`
            // de zaten bu yerel sayıma göre tutuluyor (bkz. ChatViewModel.markReadNow).
            let displayMessages: [Message]
            let unread: Int
            if let localStored, !localStored.messages.isEmpty {
                displayMessages = localStored.messages
                let assistantCount = localStored.messages.filter { $0.role == .assistant }.count
                unread = max(0, assistantCount - ReadTracker.seen(conv.characterID))
            } else {
                displayMessages = convMsgs.reversed().map {
                    Message(role: ChatRole(rawValue: $0.role) ?? .assistant,
                            content: $0.content, createdAt: $0.date ?? Date())
                }
                let assistantCount = convMsgs.filter { !$0.isUser }.count
                unread = max(0, assistantCount - ReadTracker.seen(conv.characterID))
            }
            // Sohbet geçmişini önbelleğe al → ChatView anında açılır, bildirimle
            // gelen mesajı da görür (bayat sunucu-only önbellekle ezilmesin diye).
            store.chatCache[ch.id] = displayMessages

            let last: LastMessage? = displayMessages.last.map {
                LastMessage(conversationID: conv.id, content: $0.content,
                            role: $0.role.rawValue, createdAt: Self.iso8601.string(from: $0.createdAt))
            }
            return ChatItem(character: ch, conversationID: conv.id,
                            last: last, unread: unread, updatedAt: conv.updatedAt)
        }
        isLoading = false
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Chats")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            roundIcon("slider.horizontal.3")
            roundIcon("square.and.pencil")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func roundIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(.white.opacity(0.08), in: Circle())
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16)).foregroundStyle(.white.opacity(0.5))
            TextField("", text: $searchText,
                      prompt: Text("Search chats").foregroundColor(.white.opacity(0.5)))
                .foregroundStyle(.white)
                .tint(AppColor.pink)
        }
        .padding(.horizontal, 16).frame(height: 44)
        .background(.white.opacity(0.08), in: Capsule())
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    // MARK: Mesajlar

    private var messagesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ALL MESSAGES")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

            ForEach(filtered) { item in
                NavigationLink(value: item.character) {
                    ChatHistoryRow(item: item,
                                   isTyping: store.typingCharacterIDs.contains(item.character.id))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Boş durum

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 50))
                .foregroundStyle(AppColor.pink.opacity(0.85))
            Text("No chats yet")
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text("Message someone you liked in Discover to start chatting 💬")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - Satır

private struct ChatHistoryRow: View {
    let item: ChatItem
    let isTyping: Bool
    @Environment(CharacterStore.self) private var store
    @State private var showProfile = false
    @State private var addSheetKind: NoteKind?
    @State private var showBlockConfirm = false
    @State private var isBlocked: Bool

    private var hasUnread: Bool { item.unread > 0 }

    init(item: ChatItem, isTyping: Bool) {
        self.item = item
        self.isTyping = isTyping
        _isBlocked = State(initialValue: BlockedCharactersStore.isBlocked(item.character.id))
    }

    var body: some View {
        HStack(spacing: 12) {
            // Avatar → opens CharacterProfileView (which has Chat + Gallery buttons)
            Button { showProfile = true } label: {
                CachedImage(url: item.character.avatarURL ?? item.character.photoURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: { AppColor.pink }
                .frame(width: 52, height: 52)
                .clipShape(Circle())
                .overlay {
                    if isBlocked {
                        Circle().fill(Color.black.opacity(0.6))
                        Image(systemName: "nosign")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isBlocked {
                        Circle().fill(Color(hex: 0x22C55E))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(AppColor.bg, lineWidth: 2))
                    }
                }
            }
            .buttonStyle(.plain)
            .fullScreenCover(isPresented: $showProfile) {
                CharacterProfileView(character: item.character)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.character.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                subtitle
                    .font(.system(size: 14, weight: hasUnread ? .semibold : .regular))
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(relativeTime(item.last?.createdAt ?? item.updatedAt))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hasUnread ? AppColor.pink : .white.opacity(0.5))
                rightAccessory
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(hasUnread ? AppColor.pink.opacity(0.08) : .clear)
        .contextMenu {
            Button { showProfile = true } label: { Label("View Profile", systemImage: "person.circle") }
            Button { addSheetKind = .memory } label: { Label("Add Memory", systemImage: "sparkles") }
            Button { addSheetKind = .behavior } label: { Label("Add Behavior", systemImage: "face.smiling") }
            Button(role: .destructive) {
                Task { await ChatMaintenance.clearChat(character: item.character, store: store) }
            } label: { Label("Clear Chat", systemImage: "trash") }
            if isBlocked {
                Button {
                    BlockedCharactersStore.unblock(item.character.id)
                    isBlocked = false
                } label: { Label("Unblock", systemImage: "checkmark.circle") }
            } else {
                Button(role: .destructive) { showBlockConfirm = true } label: { Label("Block", systemImage: "nosign") }
            }
        }
        .sheet(item: $addSheetKind) { kind in
            AddCharacterNoteSheet(character: item.character, kind: kind)
        }
        .alert("Block this character?", isPresented: $showBlockConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Block", role: .destructive) {
                BlockedCharactersStore.block(item.character.id)
                isBlocked = true
            }
        } message: {
            Text("\(item.character.name) will no longer appear in Discover. This chat won't be deleted.")
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if isTyping {
            Text("Typing…")
                .italic()
                .foregroundStyle(AppColor.pink)
        } else if let last = item.last {
            Group {
                if last.isUser {
                    Text("You: \(last.content)")
                } else {
                    Text(last.content)
                }
            }
                .foregroundStyle(hasUnread ? .white : .white.opacity(0.6))
        } else {
            Text(item.character.tagline)
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    @ViewBuilder
    private var rightAccessory: some View {
        if hasUnread {
            Text("\(item.unread)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(minWidth: 20, minHeight: 20)
                .padding(.horizontal, 5)
                .background(AppColor.pink, in: Capsule())
        } else if let last = item.last, last.isUser {
            Image(systemName: "checkmark.message.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}

/// ISO8601 zaman damgasını kısa göreli metne çevirir (şimdi, 5dk, 2sa, Dün…).
private func relativeTime(_ iso: String?) -> String {
    guard let iso else { return "" }
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = fmt.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    guard let date else { return "" }
    let s = Date().timeIntervalSince(date)
    if s < 60 { return String(localized: "now") }
    if s < 3600 { return "\(Int(s/60))m" }
    if s < 86400 { return "\(Int(s/3600))h" }
    if s < 172800 { return String(localized: "Yesterday") }
    return "\(Int(s/86400))d"
}

#Preview {
    ChatListView()
        .environment(CharacterStore())
}
