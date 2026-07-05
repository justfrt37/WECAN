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
    @State private var addSheetKind: NoteKind?
    @State private var showBlockConfirm = false
    @State private var isBlocked: Bool
    @State private var recognizer = SpeechRecognizer()
    @State private var voice = VoicePlayer()
    @State private var didPrefill = false
    @State private var levelUpBanner: ChatViewModel.LevelUpEvent?
    @State private var avatarPulse = false
    /// Bir mesaja dokununca saatini göster — tekrar dokununca gizlenir.
    @State private var expandedMessageID: Message.ID?

    /// Tab içinde gösterilince alttaki tab bar'ın üstünde kalması için boşluk.
    var bottomInset: CGFloat = 0
    var showsBackButton: Bool = true
    /// Keşfet'ten "tanışmak ister misin?" onayından geldiyse — mesaj kutusuna
    /// önceden yazılır, kullanıcı düzenleyip gönderebilir (AI'ın kendi selamını değiştirmez).
    var prefillText: String? = nil

    init(character: Character, bottomInset: CGFloat = 0, showsBackButton: Bool = true, prefillText: String? = nil) {
        _viewModel = State(initialValue: ChatViewModel(character: character))
        _isBlocked = State(initialValue: BlockedCharactersStore.isBlocked(character.id))
        self.bottomInset = bottomInset
        self.showsBackButton = showsBackButton
        self.prefillText = prefillText
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [AppColor.bg, AppColor.bg2, AppColor.bg],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .background(AppColor.card.opacity(0.8))
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
            if !didPrefill, let prefillText, !prefillText.isEmpty {
                viewModel.inputText = prefillText
                didPrefill = true
            }
        }
        .fullScreenCover(isPresented: $showGallery) {
            GalleryView(character: viewModel.character)
        }
        .fullScreenCover(isPresented: $showProfile) {
            CharacterProfileView(character: viewModel.character)
        }
        .sheet(item: $addSheetKind) { kind in
            AddCharacterNoteSheet(character: viewModel.character, kind: kind)
        }
        .alert("Block this character?", isPresented: $showBlockConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Block", role: .destructive) {
                BlockedCharactersStore.block(viewModel.character.id)
                isBlocked = true
            }
        } message: {
            Text("\(viewModel.character.name) will no longer appear in Discover. This chat won't be deleted.")
        }
        .onChange(of: viewModel.levelUpEvent) { _, newValue in
            guard let event = newValue else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                levelUpBanner = event
                avatarPulse = true
            }
            Task {
                try? await Task.sleep(nanoseconds: 2_800_000_000)
                withAnimation(.easeInOut(duration: 0.4)) {
                    levelUpBanner = nil
                    avatarPulse = false
                }
                viewModel.levelUpEvent = nil
            }
        }
    }

    // MARK: Header

    private var header: some View {
        ZStack {
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
                                Text("Online")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            Text("Level \(viewModel.relationshipLevel) · \(viewModel.relationshipStage)")
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
            .opacity(levelUpBanner == nil ? 1 : 0)

            if let event = levelUpBanner {
                levelUpBannerView(event)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func levelUpBannerView(_ event: ChatViewModel.LevelUpEvent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "heart.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, value: event.toLevel)
            VStack(alignment: .leading, spacing: 1) {
                Text("Relationship level up! 💕")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Text("\(event.fromStage) → \(event.toStage)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(
            LinearGradient(colors: [AppColor.pink, AppColor.amber],
                           startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private var avatarWithLevel: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 2.5)
            Circle().trim(from: 0, to: viewModel.levelProgress)
                .stroke(LinearGradient(colors: [AppColor.pink, AppColor.amber],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: viewModel.levelProgress)
            CachedImage(url: viewModel.character.avatarURL ?? viewModel.character.photoURL) { image in
                image.resizable().scaledToFill()
            } placeholder: { AppColor.pink }
            .frame(width: 38, height: 38)
            .clipShape(Circle())
        }
        .frame(width: 48, height: 48)
        .scaleEffect(avatarPulse ? 1.15 : 1)
        .shadow(color: AppColor.pink.opacity(avatarPulse ? 0.9 : 0), radius: avatarPulse ? 12 : 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.5).repeatCount(3, autoreverses: true), value: avatarPulse)
        .overlay(alignment: .bottomLeading) {
            Text("\(viewModel.relationshipLevel)")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(
                    LinearGradient(colors: [AppColor.pink, AppColor.amber],
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
                Button { showProfile = true } label: { Label("View Profile", systemImage: "person.circle") }
                Button { addSheetKind = .memory } label: { Label("Add Memory", systemImage: "sparkles") }
                Button { addSheetKind = .behavior } label: { Label("Add Behavior", systemImage: "face.smiling") }
                Button(role: .destructive) { viewModel.clearChat() } label: { Label("Clear Chat", systemImage: "trash") }
                if isBlocked {
                    Button {
                        BlockedCharactersStore.unblock(viewModel.character.id)
                        isBlocked = false
                    } label: { Label("Unblock", systemImage: "checkmark.circle") }
                } else {
                    Button(role: .destructive) { showBlockConfirm = true } label: { Label("Block", systemImage: "nosign") }
                }
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
                                   isSpeaking: voice.speakingMessageID == message.id,
                                   showsTimestamp: expandedMessageID == message.id,
                                   onTap: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedMessageID = expandedMessageID == message.id ? nil : message.id
                            }
                        }, onSpeak: {
                            if voice.speakingMessageID == message.id {
                                voice.stop()
                            } else {
                                voice.speak(message.content, id: message.id)
                            }
                        }, isVoicePlaying: voice.speakingMessageID == message.id, onPlayVoice: {
                            if voice.speakingMessageID == message.id {
                                voice.stop()
                            } else if let path = message.voiceLocalPath {
                                voice.playFile(at: path, id: message.id)
                            }
                        })
                        .id(message.id)
                    }
                    if viewModel.showsTypingBubble {
                        Group {
                            if viewModel.isSendingImageReply {
                                ImagePendingIndicator()
                            } else if viewModel.isSendingVoiceReply {
                                VoicePendingIndicator()
                            } else {
                                TypingIndicator()
                            }
                        }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .id("typing")
                    }
                }
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)   // ilk girişte en altta başla
            .onChange(of: viewModel.messages.count) { scrollToBottom(proxy) }
            .onChange(of: viewModel.showsTypingBubble) { scrollToBottom(proxy) }
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

    // MARK: Mod düğmeleri

    private var quickReplyRow: some View {
        HStack(spacing: 10) {
            modeButton(
                icon: viewModel.isVoiceArmed ? "waveform.circle.fill" : "waveform.circle",
                label: String(localized: "Send me a voice"),
                isArmed: viewModel.isVoiceArmed
            ) {
                viewModel.isVoiceArmed.toggle()
                if viewModel.isVoiceArmed { viewModel.isImageArmed = false }
            }

            modeButton(
                icon: viewModel.isImageArmed ? "camera.circle.fill" : "camera.circle",
                label: String(localized: "Send me a photo"),
                isArmed: viewModel.isImageArmed
            ) {
                viewModel.isImageArmed.toggle()
                if viewModel.isImageArmed { viewModel.isVoiceArmed = false }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(AppColor.card.opacity(0.6))
    }

    private func modeButton(icon: String, label: String, isArmed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18))
                Text(label).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isArmed ? AppColor.pink : .white.opacity(0.85))
            .padding(.horizontal, 14).frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(isArmed ? AppColor.pink.opacity(0.15) : .white.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(isArmed ? AppColor.pink.opacity(0.5) : .white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isSending || viewModel.isLoadingHistory)
    }

    // MARK: Input

    private var inputPlaceholder: String {
        if viewModel.isImageArmed { return String(localized: "Describe the photo…") }
        if viewModel.isVoiceArmed { return String(localized: "What do you want to hear?") }
        return String(localized: "Message…")
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "face.smiling")
                    .font(.system(size: 20)).foregroundStyle(.white.opacity(0.5))
                TextField("", text: $viewModel.inputText,
                          prompt: Text(inputPlaceholder).foregroundColor(.white.opacity(0.4)),
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
            .overlay(Capsule().strokeBorder(
                (recognizer.isRecording || viewModel.isVoiceArmed) ? AppColor.pink.opacity(0.6) : .white.opacity(0.1),
                lineWidth: viewModel.isVoiceArmed ? 2 : 1
            ))

            Button {
                if viewModel.isImageArmed {
                    viewModel.sendImageRequest()
                } else if viewModel.isVoiceArmed {
                    viewModel.sendVoiceRequest()
                } else {
                    viewModel.send()
                }
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(
                        LinearGradient(colors: [AppColor.pink, AppColor.amber],
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
        .background(AppColor.card.opacity(0.9))
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
    var showsTimestamp: Bool = false
    var onTap: (() -> Void)? = nil
    var onSpeak: (() -> Void)? = nil
    var isVoicePlaying: Bool = false
    var onPlayVoice: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if message.isUser { Spacer(minLength: 50) }

            if showsTimestamp, message.isUser {
                timestampLabel
            }

            if message.isVoice {
                VoiceMessageBubble(message: message, isUser: message.isUser, isPlaying: isVoicePlaying, onTap: { onPlayVoice?() })
            } else if let imageURL = message.imageURL {
                // Foto mesajı (kızın gönderdiği fotoğraf)
                CachedImage(url: imageURL) { img in
                    img.resizable().scaledToFill()
                } placeholder: { AppColor.card }
                .frame(width: 200, height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1), lineWidth: 1))
                .onTapGesture { onTap?() }
            } else {
                Text(message.content)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background {
                        if message.isUser {
                            LinearGradient(colors: [AppColor.pink, AppColor.amber],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        } else {
                            Color.white.opacity(0.1)
                        }
                    }
                    .clipShape(.rect(topLeadingRadius: 16, bottomLeadingRadius: message.isUser ? 16 : 4,
                                     bottomTrailingRadius: message.isUser ? 4 : 16, topTrailingRadius: 16))
                    .onTapGesture { onTap?() }
            }

            if showsTimestamp, !message.isUser {
                timestampLabel
            }

            // Kızın mesajını seslendir (oynat/durdur)
            if !message.isUser, message.imageURL == nil, !message.isVoice, let onSpeak {
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

    private var timestampLabel: some View {
        Text(message.createdAt, format: .dateTime.hour().minute())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            .fixedSize()
            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: message.isUser ? .trailing : .leading)))
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

// MARK: - Sesli mesaj bekleme animasyonu (3-nokta yazma balonundan BİLEREK farklı)

private struct VoicePendingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(AppColor.pink.opacity(0.9))
                    .frame(width: 3, height: animating ? barHeight(i) : 6)
                    .animation(
                        .easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.12),
                        value: animating
                    )
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(AppColor.pink.opacity(0.12))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(AppColor.pink.opacity(0.3), lineWidth: 1))
        .onAppear { animating = true }
    }

    private func barHeight(_ index: Int) -> CGFloat {
        [10, 18, 8, 20, 12][index % 5]
    }
}

private struct ImagePendingIndicator: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.fill")
                .font(.system(size: 14))
                .foregroundStyle(AppColor.pink)
                .opacity(pulse ? 1 : 0.4)
            Text("Generating photo…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 14).frame(height: 34)
        .background(AppColor.card, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
