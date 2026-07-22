//
//  ChatListView.swift
//  Chat sekmesi — "Chat History" tasarımı.
//  Başlık + arama + son mesajlı sohbet satırları (okunmamış rozeti + Yazıyor).
//

import SwiftUI

private struct ChatItem: Identifiable, Codable {
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
    /// Şu an açık (swipe ile "Sil" görünen) tek satır — biri açılınca diğeri
    /// kapanır; başka yere dokununca nil'e çekilip hepsi kapanır.
    @State private var openRowID: UUID?

    private let service = ConversationsService()

    private var filtered: [ChatItem] {
        guard !searchText.isEmpty else { return items }
        return items.filter { $0.character.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// Sohbeti listeden kaldır + SUNUCU kaydını sil (bkz. ChatMaintenance).
    /// "Sıfır yerel": artık disk önbelleği / tombstone yok — sunucu silme +
    /// no-create-on-open zaten dirilmeyi engelliyor (bkz. chat/index.ts).
    private func deleteItem(_ item: ChatItem, animated: Bool = true) {
        if animated {
            withAnimation { items.removeAll { $0.character.id == item.character.id } }
        } else {
            // Basılı tut → "bam" anında sil, animasyon yok (bkz. kullanıcı talebi).
            items.removeAll { $0.character.id == item.character.id }
        }
        Task { await ChatMaintenance.clearChat(character: item.character, store: store) }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [AppColor.bg, AppColor.bg2, AppColor.bg],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                // Açık bir "Sil" satırı varken boş bir yere dokununca kapansın.
                .onTapGesture { if openRowID != nil { openRowID = nil } }

            // Başlık + arama + "ALL MESSAGES" SABİT kalır; yalnızca mesaj
            // listesi (ALL MESSAGES'ın altındaki kısım) kayar.
            VStack(alignment: .leading, spacing: 0) {
                header
                searchBar
                if isLoading {
                    ProgressView().tint(.white)
                        .frame(maxWidth: .infinity).padding(.top, 60)
                    Spacer()
                } else if items.isEmpty {
                    emptyState
                    Spacer()
                } else {
                    allMessagesLabel
                    ScrollView {
                        // VStack (Lazy DEĞİL) — kasıtlı: LazyVStack görünmeyen
                        // satırların yüksekliğini TAHMİN ediyor, tahmin şaşınca
                        // satırlar arasında boşluklar oluşuyordu (bkz. kullanıcı
                        // ekran görüntüsü). Sohbet listesi kısa, hepsini ölçmek ucuz.
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(filtered) { item in
                                // Sola çekince "Sil" butonu belirir + AÇIK kalır
                                // (açmadan chat'i açmaz); basılı tutunca menüde de
                                // "Sil" var (bkz. kullanıcı talebi).
                                SwipeToDeleteRow(
                                    id: item.character.id,
                                    openRowID: $openRowID,
                                    onTap: { store.pendingChatCharacter = item.character },
                                    onDelete: { deleteItem(item) }
                                ) {
                                    ChatHistoryRow(item: item,
                                                   isTyping: store.typingCharacterIDs.contains(item.character.id),
                                                   // Basılı tut menüsündeki "Sil" → animasyonsuz, anında.
                                                   onDelete: { deleteItem(item, animated: false) })
                                }
                            }
                        }
                        .padding(.bottom, 100) // tab bar boşluğu
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .task { await load() }
        .onChange(of: store.typingCharacterIDs) { Task { await load() } }
        .onChange(of: store.conversationsVersion) { Task { await load() } }
    }

    private func load() async {
        // "Sıfır yerel": TEK kaynak sunucu. Disk önbelleği / yerel-birleşim /
        // tombstone YOK — yalnızca sunucudaki konuşmalar + mesajlar gösterilir.
        async let convsT = service.fetchConversations()
        async let msgsT = service.fetchAllMessages()
        let (convs, msgs) = await (convsT, msgsT)

        // Mesajları konuşmaya göre grupla (desc sıralı geldi — en yeni önce).
        var byConv: [UUID: [LastMessage]] = [:]
        for m in msgs { byConv[m.conversationID, default: []].append(m) }

        items = convs.compactMap { conv in
            guard let ch = store.characters.first(where: { $0.id == conv.characterID }) else { return nil }
            let convMsgs = byConv[conv.id] ?? []
            // Yalnızca gerçekten mesajı olan sohbetler listelenir — boş (yalnız
            // durum) satır hayalet sohbet gibi görünmesin.
            guard !convMsgs.isEmpty else { return nil }

            // ChatView anında açılsın diye geçmişi bellek-içi önbelleğe al (asc).
            let displayMessages: [Message] = convMsgs.reversed().map {
                Message(role: ChatRole(rawValue: $0.role) ?? .assistant,
                        content: $0.content, createdAt: $0.date ?? Date())
            }
            store.chatCache[ch.id] = displayMessages

            let assistantCount = convMsgs.filter { !$0.isUser }.count
            let unread = max(0, assistantCount - ReadTracker.seen(conv.characterID))
            // Önizleme en yeni mesajdan (convMsgs desc → .first) — sunucudaki
            // `kind` (text/image/voice) korunur, WhatsApp tarzı önizleme için.
            let last: LastMessage? = convMsgs.first.map {
                LastMessage(conversationID: conv.id, content: $0.content,
                            role: $0.role, createdAt: $0.createdAt, kind: $0.kind)
            }
            return ChatItem(character: ch, conversationID: conv.id,
                            last: last, unread: unread, updatedAt: conv.updatedAt)
        }

        items.sort { lhs, rhs in
            let lhsDate = parseISO8601(lhs.last?.createdAt) ?? parseISO8601(lhs.updatedAt) ?? .distantPast
            let rhsDate = parseISO8601(rhs.last?.createdAt) ?? parseISO8601(rhs.updatedAt) ?? .distantPast
            return lhsDate > rhsDate
        }
        // Karakter başına TEK satır (aynı karaktere ait birden çok konuşma
        // olabilir) — sıralama sonrası ilk (en yeni) tutulur.
        var seenCharacterIDs = Set<UUID>()
        items = items.filter { seenCharacterIDs.insert($0.character.id).inserted }
        isLoading = false
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Chats")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
        }
        // Sağda TokenBadge için yer bırakılıyor (bkz. MainTabView) — burada
        // hiçbir işlevi olmayan "filter"/"new chat" ikonları kaldırıldı
        // (ikisi de Button'a sarılı değildi, dokunulamıyordu).
        .padding(.leading, 20)
        .padding(.trailing, 96)
        .padding(.top, 12)
        .padding(.bottom, 8)
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

    private var allMessagesLabel: some View {
        Text("ALL MESSAGES")
            .font(.system(size: 11, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
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
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - Satır

private struct ChatHistoryRow: View {
    let item: ChatItem
    let isTyping: Bool
    var onDelete: () -> Void = {}
    @Environment(CharacterStore.self) private var store
    @State private var showProfile = false
    @State private var addSheetKind: NoteKind?
    @State private var showBlockConfirm = false
    @State private var isBlocked: Bool

    private var hasUnread: Bool { item.unread > 0 }

    init(item: ChatItem, isTyping: Bool, onDelete: @escaping () -> Void = {}) {
        self.item = item
        self.isTyping = isTyping
        self.onDelete = onDelete
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
        // Sabit satır yüksekliği — tüm satırlar tekdüze olsun, boşluk oluşmasın.
        .frame(height: 72)
        .background(hasUnread ? AppColor.pink.opacity(0.08) : .clear)
        .contextMenu {
            Button { showProfile = true } label: { Label("View Profile", systemImage: "person.circle") }
            Button { addSheetKind = .memory } label: { Label("Add Memory", systemImage: "sparkles") }
            Button { addSheetKind = .behavior } label: { Label("Add Behavior", systemImage: "face.smiling") }
            Button(role: .destructive) {
                Task { await ChatMaintenance.clearChat(character: item.character, store: store) }
            } label: { Label("Clear Chat", systemImage: "eraser") }
            Button(role: .destructive) { onDelete() } label: { Label("Sil", systemImage: "trash") }
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
                if last.isVoice {
                    // WhatsApp gibi: 🎤 Sesli mesaj
                    HStack(spacing: 4) {
                        Image(systemName: "mic.fill")
                        Text(last.isUser ? "You: \(String(localized: "Voice message"))" : String(localized: "Voice message"))
                    }
                } else if last.isImage {
                    // WhatsApp gibi: 📷 Fotoğraf
                    HStack(spacing: 4) {
                        Image(systemName: "camera.fill")
                        Text(last.isUser ? "You: \(String(localized: "Photo"))" : String(localized: "Photo"))
                    }
                } else if last.isUser {
                    Text("You: \(last.content)")
                } else {
                    Text(last.content)
                }
            }
                .foregroundStyle(hasUnread ? .white : .white.opacity(0.6))
        } else {
            Text(item.character.localizedTagline)
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    @ViewBuilder
    private var rightAccessory: some View {
        // Okunmamış sayısı rozeti kalır; "okundu" (checkmark) ikonu kaldırıldı
        // (bkz. kullanıcı talebi: saat altında ikon olmasın).
        if hasUnread {
            Text("\(item.unread)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(minWidth: 20, minHeight: 20)
                .padding(.horizontal, 5)
                .background(AppColor.pink, in: Capsule())
        }
    }
}

/// Sola çekince "Sil" butonu beliren satır sarmalayıcı. List kullanmadan
/// (özel stil + chevron'suz NavigationLink korunsun diye) kendi swipe'ı:
/// - Yatay-baskın sürükleme sola açar/sağa kapatır (simultaneousGesture → dikey
///   scroll ve dokunma-ile-açma çakışmaz).
/// - Sil butonu içeriğin SAĞINDA, kapalıyken ekran dışında (clipped).
private struct SwipeToDeleteRow<Content: View>: View {
    let id: UUID
    @Binding var openRowID: UUID?
    let onTap: () -> Void
    let onDelete: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var lastOffset: CGFloat = 0
    private let deleteWidth: CGFloat = 88
    private let rowHeight: CGFloat = 72

    private var isOpen: Bool { offset < 0 }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                content()
                    .frame(width: geo.size.width)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Açıkken dokunmak KAPATIR (chat'i açmaz); kapalıyken açar.
                        if isOpen { close() }
                        else { openRowID = nil; onTap() }
                    }
                Button {
                    onDelete()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "trash.fill").font(.system(size: 18, weight: .semibold))
                        Text("Sil").font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: deleteWidth)
                    .frame(maxHeight: .infinity)
                    .background(Color.red)
                }
                .buttonStyle(.plain)
            }
            .offset(x: offset)
            .simultaneousGesture(
                DragGesture(minimumDistance: 15)
                    .onChanged { v in
                        // Yalnızca yatay-baskın hareket — dikey scroll'a karışma.
                        guard abs(v.translation.width) > abs(v.translation.height) else { return }
                        offset = min(0, max(-deleteWidth, lastOffset + v.translation.width))
                    }
                    .onEnded { v in
                        guard abs(v.translation.width) > abs(v.translation.height) else { return }
                        let shouldOpen = offset < -deleteWidth / 2
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            offset = shouldOpen ? -deleteWidth : 0
                        }
                        lastOffset = offset
                        // Bu satır açıldıysa "tek açık satır" yap → diğerleri kapanır.
                        if shouldOpen { openRowID = id }
                        else if openRowID == id { openRowID = nil }
                    }
            )
        }
        .frame(height: rowHeight)
        .clipped()
        // Başka bir satır açıldı (ya da hepsi kapatıldı) → bunu kapat.
        .onChange(of: openRowID) { _, newID in
            if newID != id, offset != 0 { close() }
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { offset = 0 }
        lastOffset = 0
        if openRowID == id { openRowID = nil }
    }
}

/// ISO8601 zaman damgasını `Date`'e çevirir — sıralama için (bkz. ChatListView.load()).
private func parseISO8601(_ iso: String?) -> Date? {
    guard let iso else { return nil }
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fmt.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
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
    if s < 3600 { return String(localized: "\(Int(s/60))m") }
    if s < 86400 { return String(localized: "\(Int(s/3600))h") }
    if s < 172800 { return String(localized: "Yesterday") }
    return String(localized: "\(Int(s/86400))d")
}

#Preview {
    ChatListView()
        .environment(CharacterStore())
}
