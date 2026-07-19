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

    /// Sohbet listesinin diskteki önbelleği — sekme her açıldığında sunucu
    /// cevabını beklemeden ANINDA bir önceki durumu gösterir, arkada tazeler.
    private let cacheURL: URL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("chatlist_cache.json")

    private var filtered: [ChatItem] {
        guard !searchText.isEmpty else { return items }
        return items.filter { $0.character.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// Sohbeti listeden kaldır + sunucu/cihaz kaydını sil (bkz. ChatMaintenance).
    /// Ayrıca kalıcı bir "tombstone" (silinme zamanı) yazılır — sunucu silme
    /// gecikmesi / önbellek yarışı / chat açılınca yeniden-oluşma OLSA BİLE
    /// silinen sohbet, gerçekten YENİ bir aktivite gelene kadar listede görünmez.
    private func deleteItem(_ item: ChatItem, animated: Bool = true) {
        setTombstone(item.character.id)
        if animated {
            withAnimation { items.removeAll { $0.character.id == item.character.id } }
        } else {
            // Basılı tut → "bam" anında sil, animasyon yok (bkz. kullanıcı talebi).
            items.removeAll { $0.character.id == item.character.id }
        }
        saveCachedItems(items)
        Task { await ChatMaintenance.clearChat(character: item.character, store: store) }
    }

    // MARK: - Silinmiş sohbet "tombstone"ları (kalıcı, UserDefaults)

    private static let tombstonesKey = "chatlist.deleted.tombstones.v1"

    private func tombstones() -> [String: Double] {
        (UserDefaults.standard.dictionary(forKey: Self.tombstonesKey) as? [String: Double]) ?? [:]
    }
    private func setTombstone(_ id: UUID) {
        var t = tombstones()
        t[id.uuidString] = Date().timeIntervalSince1970
        UserDefaults.standard.set(t, forKey: Self.tombstonesKey)
    }
    private func clearTombstone(_ id: UUID) {
        var t = tombstones()
        t.removeValue(forKey: id.uuidString)
        UserDefaults.standard.set(t, forKey: Self.tombstonesKey)
    }

    /// Tombstone'lanmış sohbetleri gizler; ama silinme zamanından SONRA gerçek
    /// bir aktivite olduysa (kullanıcı tekrar yazışmaya başladı) tombstone'u
    /// kaldırıp sohbeti geri gösterir.
    private func applyTombstones(_ list: [ChatItem]) -> [ChatItem] {
        let tomb = tombstones()
        guard !tomb.isEmpty else { return list }
        return list.filter { item in
            guard let ts = tomb[item.character.id.uuidString] else { return true }
            let latest = parseISO8601(item.last?.createdAt) ?? parseISO8601(item.updatedAt) ?? .distantPast
            if latest.timeIntervalSince1970 > ts + 1 {   // silmeden SONRA yeni aktivite → geri getir
                clearTombstone(item.character.id)
                return true
            }
            return false   // hâlâ silinmiş sayılır → gizle
        }
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
        // Diskteki önbellekten ANINDA göster — sadece ilk (soğuk) yüklemede;
        // typing-değişikliği gibi sonraki tetiklemelerde zaten canlı veri var.
        if items.isEmpty, let cached = loadCachedItems(), !cached.isEmpty {
            items = applyTombstones(cached)
            isLoading = false
        }

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
                            role: $0.role.rawValue, createdAt: Self.iso8601.string(from: $0.createdAt),
                            kind: Self.previewKind(for: $0))
            }
            return ChatItem(character: ch, conversationID: conv.id,
                            last: last, unread: unread, updatedAt: conv.updatedAt)
        }
        // Sunucuda konuşması olmayan ama YEREL geçmişi olan sohbetleri de ekle
        // (ör. onboarding sonrası açılan chat, bildirimle enjekte edilenler) —
        // liste yalnızca sunucu konuşmalarını gösterince bunlar hiç görünmüyordu.
        let listedIDs = Set(items.map { $0.character.id })
        for charID in LocalConversationStore.shared.allCharacterIDs() where !listedIDs.contains(charID) {
            guard let ch = store.characters.first(where: { $0.id == charID }),
                  let localStored = LocalConversationStore.shared.load(for: charID),
                  !localStored.messages.isEmpty else { continue }
            store.chatCache[charID] = localStored.messages
            let assistantCount = localStored.messages.filter { $0.role == .assistant }.count
            let unread = max(0, assistantCount - ReadTracker.seen(charID))
            let last: LastMessage? = localStored.messages.last.map {
                LastMessage(conversationID: charID, content: $0.content,
                            role: $0.role.rawValue, createdAt: Self.iso8601.string(from: $0.createdAt),
                            kind: Self.previewKind(for: $0))
            }
            items.append(ChatItem(character: ch, conversationID: charID,
                                   last: last, unread: unread, updatedAt: nil))
        }

        items.sort { lhs, rhs in
            let lhsDate = parseISO8601(lhs.last?.createdAt) ?? parseISO8601(lhs.updatedAt) ?? .distantPast
            let rhsDate = parseISO8601(rhs.last?.createdAt) ?? parseISO8601(rhs.updatedAt) ?? .distantPast
            return lhsDate > rhsDate
        }
        // Karakter başına TEK satır — aynı karaktere ait birden çok konuşma
        // (ChatItem.id == character.id) ForEach'te kimlik çakışması + duplike
        // satır + "birini çekince ikisi açılıyor" hatasına yol açıyordu.
        // Sıralama sonrası ilk (en yeni) satır tutulur.
        var seenCharacterIDs = Set<UUID>()
        items = items.filter { seenCharacterIDs.insert($0.character.id).inserted }
        // Silinmiş (tombstone'lu) sohbetleri gizle — sunucu/önbellek gecikse bile
        // geri gelmesin (bkz. applyTombstones).
        items = applyTombstones(items)
        isLoading = false
        saveCachedItems(items)
    }

    private func loadCachedItems() -> [ChatItem]? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode([ChatItem].self, from: data)
    }

    private func saveCachedItems(_ items: [ChatItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Son-mesaj önizleme türü — foto (üretilmiş/ödeme bekleyen/kullanıcı
    /// fotosu) ve ses (üretilmiş/ödeme bekleyen) dahil. Liste satırında
    /// WhatsApp gibi "📷 Fotoğraf" / "🎤 Sesli mesaj" göstermek için (bkz. subtitle).
    private static func previewKind(for m: Message) -> String {
        if m.isVoice || m.isPendingVoice { return "voice" }
        if m.imageURL != nil || m.isPendingImage || m.isUserPhoto { return "image" }
        return "text"
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
            Text(item.character.tagline)
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
