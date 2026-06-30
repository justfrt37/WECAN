//
//  ChatView.swift
//  Sohbet ekranı — "Lumi - Chat Conversation" tasarımı.
//

import SwiftUI

struct ChatView: View {
    @State private var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(CharacterStore.self) private var store

    @State private var showGallery = false
    @State private var showProfile = false
    @State private var addSheetTitle: String?
    @State private var addSheetText = ""
    @State private var showBlockConfirm = false
    @State private var recognizer = SpeechRecognizer()
    @State private var voice = VoicePlayer()

    /// Tab içinde gösterilince alttaki tab bar'ın üstünde kalması için boşluk.
    var bottomInset: CGFloat = 0
    var showsBackButton: Bool = true

    private let quickReplies = ["Selam 👋", "Naber? 💕", "Seni özledim", "Bugün ne yaptın?"]
    private let maxLevel = 10

    init(character: Character, bottomInset: CGFloat = 0, showsBackButton: Bool = true) {
        _viewModel = State(initialValue: ChatViewModel(character: character))
        self.bottomInset = bottomInset
        self.showsBackButton = showsBackButton
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [AppColor.bg, AppColor.bg2, AppColor.bg],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .background(Color(hex: 0x1A0826).opacity(0.8))
                    .overlay(Rectangle().frame(height: 1).foregroundStyle(.white.opacity(0.08)),
                             alignment: .bottom)

                if viewModel.isLoadingHistory {
                    Spacer(); ProgressView().tint(.white); Spacer()
                } else {
                    messagesList
                }

                if let error = viewModel.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .padding(.horizontal).padding(.top, 4)
                }

                quickReplyRow
                inputBar
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { viewModel.isVisible = true }
        .onDisappear { viewModel.isVisible = false }
        .task {
            viewModel.store = store
            viewModel.isVisible = true
            await viewModel.loadHistory()
        }
        .fullScreenCover(isPresented: $showGallery) {
            GalleryView(character: viewModel.character)
        }
        .fullScreenCover(isPresented: $showProfile) {
            CharacterProfileView(character: viewModel.character)
        }
        .sheet(isPresented: Binding(get: { addSheetTitle != nil },
                                    set: { if !$0 { addSheetTitle = nil; addSheetText = "" } })) {
            addSheet
        }
        .alert("Bu karakteri engelle?", isPresented: $showBlockConfirm) {
            Button("İptal", role: .cancel) {}
            Button("Engelle", role: .destructive) {
                BlockedCharactersStore.block(viewModel.character.id)
            }
        } message: {
            Text("\(viewModel.character.name) artık Keşfet'te görünmeyecek. Bu sohbet silinmeyecek.")
        }
    }

    /// "Anı Ekle" / "Davranış Ekle" için basit giriş sayfası.
    private var addSheet: some View {
        NavigationStack {
            ZStack {
                AppColor.bg.ignoresSafeArea()
                VStack(spacing: 16) {
                    Text(addSheetTitle == "Anı Ekle"
                         ? "\(viewModel.character.name) bunu hatırlasın:"
                         : "\(viewModel.character.name) böyle davransın:")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextField("", text: $addSheetText,
                              prompt: Text(addSheetTitle == "Anı Ekle" ? "Örn. doğum günüm 5 Mayıs" : "Örn. bana hep 'aşkım' de")
                                .foregroundColor(.white.opacity(0.4)), axis: .vertical)
                        .lineLimit(3...6)
                        .foregroundStyle(.white).tint(AppColor.pink)
                        .padding(12)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    Button {
                        let kind = addSheetTitle == "Anı Ekle" ? "memory" : "behavior"
                        viewModel.saveNote(kind: kind, content: addSheetText)
                        addSheetTitle = nil; addSheetText = ""
                    } label: {
                        Text("Kaydet").font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 50)
                            .background(LinearGradient(colors: [AppColor.pink, Color(hex: 0xC4A7E7)],
                                                       startPoint: .leading, endPoint: .trailing), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle(addSheetTitle ?? "")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if showsBackButton {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                }
            }

            Button { showProfile = true } label: {
                HStack(spacing: 10) {
                    avatarWithLevel
                    VStack(alignment: .leading, spacing: 1) {
                        Text(viewModel.character.name)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                        HStack(spacing: 5) {
                            Circle().fill(Color(hex: 0x4ADE80)).frame(width: 7, height: 7)
                            Text("Çevrimiçi")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Text("Seviye \(viewModel.relationshipLevel) · \(viewModel.relationshipStage)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppColor.pinkSoft)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            headerButton("photo.fill") { showGallery = true }
            headerButton("gearshape.fill", menu: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var avatarWithLevel: some View {
        let progress = min(Double(viewModel.relationshipLevel) / Double(maxLevel), 1)
        return ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 2.5)
            Circle().trim(from: 0, to: progress)
                .stroke(LinearGradient(colors: [AppColor.pink, Color(hex: 0xC4A7E7)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            CachedImage(url: viewModel.character.avatarURL ?? viewModel.character.photoURL) { image in
                image.resizable().scaledToFill()
            } placeholder: { AppColor.pink }
            .frame(width: 38, height: 38)
            .clipShape(Circle())
        }
        .frame(width: 48, height: 48)
        .overlay(alignment: .bottomLeading) {
            Text("\(viewModel.relationshipLevel)")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(
                    LinearGradient(colors: [AppColor.pink, Color(hex: 0xC4A7E7)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Circle()
                )
                .overlay(Circle().strokeBorder(AppColor.bg, lineWidth: 1.5))
                .offset(x: -2, y: 2)
        }
    }

    @ViewBuilder
    private func headerButton(_ icon: String, menu: Bool = false, action: @escaping () -> Void = {}) -> some View {
        if menu {
            Menu {
                Button { showProfile = true } label: { Label("Profili Görüntüle", systemImage: "person.circle") }
                Button { addSheetTitle = "Anı Ekle" } label: { Label("Anı Ekle", systemImage: "sparkles") }
                Button { addSheetTitle = "Davranış Ekle" } label: { Label("Davranış Ekle", systemImage: "face.smiling") }
                Button(role: .destructive) { viewModel.clearChat() } label: { Label("Sohbeti Temizle", systemImage: "trash") }
                Button(role: .destructive) { showBlockConfirm = true } label: { Label("Blok", systemImage: "nosign") }
            } label: {
                headerIcon(icon)
            }
        } else {
            Button(action: action) { headerIcon(icon) }
        }
    }

    private func headerIcon(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 16))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: 36, height: 36)
            .background(.white.opacity(0.08), in: Circle())
    }

    // MARK: Mesajlar

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.messages) { message in
                        ChatBubble(message: message,
                                   isSpeaking: voice.speakingMessageID == message.id) {
                            if voice.speakingMessageID == message.id {
                                voice.stop()
                            } else {
                                voice.speak(message.content, id: message.id)
                            }
                        }
                        .id(message.id)
                    }
                    if viewModel.isSending {
                        TypingIndicator()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .id("typing")
                    }
                }
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)   // ilk girişte en altta başla
            .onChange(of: viewModel.messages.count) { scrollToBottom(proxy) }
            .onChange(of: viewModel.isSending) { scrollToBottom(proxy) }
            .onChange(of: viewModel.isLoadingHistory) {
                if !viewModel.isLoadingHistory { scrollToBottom(proxy) }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation {
            if viewModel.isSending {
                proxy.scrollTo("typing", anchor: .bottom)
            } else if let last = viewModel.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: Hızlı yanıtlar

    private var quickReplyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(quickReplies, id: \.self) { reply in
                    Button {
                        viewModel.send(reply)
                    } label: {
                        Text(reply)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 14).frame(height: 34)
                            .background(.white.opacity(0.08), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isSending || viewModel.isLoadingHistory)
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 8)
        .background(Color(hex: 0x1A0826).opacity(0.6))
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "face.smiling")
                    .font(.system(size: 20)).foregroundStyle(.white.opacity(0.5))
                TextField("", text: $viewModel.inputText,
                          prompt: Text("Mesaj…").foregroundColor(.white.opacity(0.4)),
                          axis: .vertical)
                    .foregroundStyle(.white)
                    .lineLimit(1...4)
                    .tint(AppColor.pink)
                Image(systemName: "camera")
                    .font(.system(size: 20)).foregroundStyle(.white.opacity(0.5))
                Button { toggleRecording() } label: {
                    Image(systemName: recognizer.isRecording ? "stop.circle.fill" : "mic.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(recognizer.isRecording ? AppColor.pink : .white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).frame(minHeight: 46)
            .background(.white.opacity(0.1), in: Capsule())
            .overlay(Capsule().strokeBorder(recognizer.isRecording ? AppColor.pink.opacity(0.6) : .white.opacity(0.1), lineWidth: 1))

            Button { viewModel.send() } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(
                        LinearGradient(colors: [AppColor.pink, Color(hex: 0xC4A7E7)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: Circle()
                    )
                    .opacity(viewModel.canSend ? 1 : 0.4)
            }
            .disabled(!viewModel.canSend)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10 + bottomInset)
        .background(Color(hex: 0x1A0826).opacity(0.9))
    }

    /// Mikrofon: kaydı başlat/durdur. Durunca metni gönderir (sesli mesaj → metin).
    private func toggleRecording() {
        if recognizer.isRecording {
            recognizer.stop()
            let text = recognizer.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { viewModel.send(text) }
        } else {
            Task {
                if !recognizer.authorized { await recognizer.requestAuthorization() }
                if recognizer.authorized { recognizer.start() }
            }
        }
    }
}

// MARK: - Mesaj balonu

private struct ChatBubble: View {
    let message: Message
    var isSpeaking: Bool = false
    var onSpeak: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if message.isUser { Spacer(minLength: 50) }

            if let imageURL = message.imageURL {
                // Foto mesajı (kızın gönderdiği fotoğraf)
                CachedImage(url: imageURL) { img in
                    img.resizable().scaledToFill()
                } placeholder: { AppColor.card }
                .frame(width: 200, height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1), lineWidth: 1))
            } else {
                Text(message.content)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background {
                        if message.isUser {
                            LinearGradient(colors: [AppColor.pink, Color(hex: 0xC4A7E7)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        } else {
                            Color.white.opacity(0.1)
                        }
                    }
                    .clipShape(.rect(topLeadingRadius: 16, bottomLeadingRadius: message.isUser ? 16 : 4,
                                     bottomTrailingRadius: message.isUser ? 4 : 16, topTrailingRadius: 16))
            }

            // Kızın mesajını seslendir (oynat/durdur)
            if !message.isUser, message.imageURL == nil, let onSpeak {
                Button(action: onSpeak) {
                    Image(systemName: isSpeaking ? "stop.circle.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(AppColor.pink)
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
            }

            if !message.isUser { Spacer(minLength: 50) }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - "yazıyor" 3 nokta animasyonu

private struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(.white.opacity(0.8))
                    .frame(width: 7, height: 7)
                    .scaleEffect(animating ? 1 : 0.45)
                    .opacity(animating ? 1 : 0.4)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2),
                               value: animating)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(Color.white.opacity(0.1))
        .clipShape(.rect(topLeadingRadius: 16, bottomLeadingRadius: 4,
                         bottomTrailingRadius: 16, topTrailingRadius: 16))
        .onAppear { animating = true }
    }
}
