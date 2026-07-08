//
//  ChatView.swift
//  Sohbet ekranı — "Lumi - Chat Conversation" tasarımı.
//

import SwiftUI
import Photos
import PhotosUI
import UIKit

struct ChatView: View {
    @State private var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(CharacterStore.self) private var store
    @Environment(TokenStore.self) private var tokenStore

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
    /// Bir foto balonuna dokununca tam ekran açılır.
    @State private var fullscreenImageURL: URL?
    /// Kullanıcının KENDİ gönderdiği fotoğrafa dokununca tam ekran (yerel, CachedImage YOK).
    @State private var fullscreenLocalImage: UIImage?

    // Sesli mesaj kaydı: `recognizer.isRecording` kayıt sırasında, `isReviewingVoice`
    // durdurulduktan sonra Send/Cancel bekleme aşamasında (bkz. plan: recording overlay).
    @State private var isReviewingVoice = false

    // Fotoğraf gönderme: kamera veya kütüphaneden seçilen görsel, gönderilmeden
    // önce tam ekran review ekranında (caption + Send/Cancel) bekler.
    @State private var showCameraPicker = false
    /// Kamera kapatılırken (`onDismiss`) okunur — aynı anda iki fullScreenCover
    /// geçişi (kamera kapan + review aç) SwiftUI'de siyah ekran/donma yaratıyordu,
    /// bu yüzden review SADECE kamera tam kapandıktan SONRA açılır.
    @State private var pendingCameraImage: UIImage?
    @State private var showLibraryPicker = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var capturedImage: UIImage?
    @State private var showPhotoReview = false
    @State private var photoCaption = ""

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

                if isBlocked {
                    blockedBar
                } else if recognizer.isRecording || isReviewingVoice {
                    VoiceRecordingOverlay(
                        isRecording: recognizer.isRecording,
                        onCancel: cancelRecording,
                        onSend: sendRecordedVoice
                    )
                    .padding(.bottom, bottomInset)
                } else {
                    quickReplyRow
                    inputBar
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { viewModel.isVisible = true }
        .onDisappear { viewModel.isVisible = false }
        .task {
            viewModel.store = store
            viewModel.tokenStore = tokenStore
            viewModel.isVisible = true
            await viewModel.loadHistory()
            if !didPrefill, let prefillText, !prefillText.isEmpty {
                viewModel.inputText = prefillText
                didPrefill = true
            }
        }
        .task {
            await viewModel.startActivityRefreshLoop()
        }
        .fullScreenCover(isPresented: $showGallery) {
            GalleryView(character: viewModel.character)
        }
        .fullScreenCover(isPresented: $showProfile) {
            CharacterProfileView(character: viewModel.character)
        }
        .sheet(isPresented: $viewModel.showPaywall) { PaywallHostView() }
        .fullScreenCover(isPresented: Binding(
            get: { fullscreenImageURL != nil },
            set: { if !$0 { fullscreenImageURL = nil } }
        )) {
            if let url = fullscreenImageURL {
                FullscreenImageView(url: url, onDismiss: { fullscreenImageURL = nil }) {
                    viewModel.reactToPrivateDownload(imageURL: url)
                }
            }
        }
        .sheet(item: $addSheetKind) { kind in
            AddCharacterNoteSheet(character: viewModel.character, kind: kind)
        }
        .fullScreenCover(isPresented: Binding(
            get: { fullscreenLocalImage != nil },
            set: { if !$0 { fullscreenLocalImage = nil } }
        )) {
            if let image = fullscreenLocalImage {
                LocalImageFullscreenView(image: image, onDismiss: { fullscreenLocalImage = nil })
            }
        }
        .fullScreenCover(isPresented: $showCameraPicker, onDismiss: {
            // Kamera TAM kapandıktan sonra review'i aç — bkz. pendingCameraImage yorumu.
            if let image = pendingCameraImage {
                capturedImage = image
                showPhotoReview = true
                pendingCameraImage = nil
            }
        }) {
            CameraPicker(
                onImage: { image in
                    pendingCameraImage = image
                    showCameraPicker = false
                },
                onCancel: { showCameraPicker = false }
            )
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showLibraryPicker, selection: $pickerItem, matching: .images)
        .fullScreenCover(isPresented: $showPhotoReview) {
            if let image = capturedImage {
                PhotoReviewView(
                    image: image,
                    caption: $photoCaption,
                    onCancel: {
                        showPhotoReview = false
                        capturedImage = nil
                        photoCaption = ""
                    },
                    onSend: {
                        showPhotoReview = false
                        viewModel.sendUserPhoto(image: image, caption: photoCaption)
                        capturedImage = nil
                        photoCaption = ""
                    }
                )
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                let data = try? await newItem.loadTransferable(type: Data.self)
                pickerItem = nil
                // Kütüphane picker'ının kendi kapanma animasyonu bitsin diye kısa
                // bekleme — aynı kamera-review çakışması burada da olabilir
                // (bkz. showCameraPicker onDismiss yorumu).
                try? await Task.sleep(nanoseconds: 300_000_000)
                if let data, let image = UIImage(data: data) {
                    capturedImage = image
                    showPhotoReview = true
                }
            }
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

    /// Availability text next to the online dot — shows "Typing…" while the
    /// typing bubble is up, reverting to the real activity/"Online" the
    /// instant it clears (bubble hides right when the reply is appended, see
    /// `ChatViewModel.send()`). Voice replies are excluded on purpose — they
    /// show their own waveform bubble (`VoicePendingIndicator`), not the
    /// 3-dot typing one, so the header shouldn't claim "Typing…" either.
    private var headerStatusLabel: String {
        if viewModel.showsTypingBubble && !viewModel.isSendingVoiceReply {
            return String(localized: "Typing…")
        }
        return viewModel.currentActivity?.label ?? String(localized: "Online")
    }

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
                            // Engellenmişse durum/aktivite HİÇ gösterilmez — çevrimiçi
                            // noktası dahil, tamamen sessiz kalır.
                            if !isBlocked {
                                HStack(spacing: 5) {
                                    Circle().fill(Color(hex: 0x4ADE80)).frame(width: 7, height: 7)
                                    Text(headerStatusLabel)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.6))
                                }
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
                // VStack (NOT LazyVStack) — kasıtlı. Lazy çizim, görünmeyen
                // satırları ölçmeden bırakıyor, bu da scrollTo/defaultScrollAnchor'ın
                // en alt konumunu TAHMİN etmesine yol açıyordu — foto ağırlıklı/
                // uzun sohbetlerde (bkz. Jasmine, 4-5 foto) tahmin yanlış çıkıp
                // mesajlar görünmez kalıyordu, sadece yukarı kaydırınca ortaya
                // çıkıyordu. Sohbet geçmişi telefon ekranı için zaten sınırlı
                // boyutta (bkz. LocalConversationStore) — hepsini baştan ölçmek ucuz.
                VStack(spacing: 10) {
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
                        }, onTapImage: { url in
                            fullscreenImageURL = url
                        }, onTapLocalImage: { image in
                            fullscreenLocalImage = image
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
            .onAppear {
                // LazyVStack ilk çizimde tüm satırları ölçmediği için
                // `.defaultScrollAnchor(.bottom)` tek başına güvenilir değil —
                // mesajlar görünmez kalıp sadece yukarı kaydırınca ortaya
                // çıkıyordu. Animasyonsuz zorla kaydır, sonra layout oturunca tekrar dene.
                scrollToBottomInstant(proxy)
                Task {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    scrollToBottomInstant(proxy)
                }
            }
        }
    }

    private func scrollToBottomInstant(_ proxy: ScrollViewProxy) {
        if let last = viewModel.messages.last {
            proxy.scrollTo(last.id, anchor: .bottom)
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

    // MARK: Engellendi barı — mesajlaşma tamamen kapalı, sadece kaldır düğmesi var.

    private var blockedBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "nosign")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(String(localized: "You've blocked this character. Unblock to send messages."))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                BlockedCharactersStore.unblock(viewModel.character.id)
                isBlocked = false
            } label: {
                Text(String(localized: "Unblock"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 34)
                    .background(
                        LinearGradient(colors: [AppColor.pink, AppColor.amber],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10 + bottomInset)
        .background(AppColor.card.opacity(0.9))
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
                Menu {
                    Button { showCameraPicker = true } label: {
                        Label(String(localized: "Take Photo"), systemImage: "camera")
                    }
                    Button { showLibraryPicker = true } label: {
                        Label(String(localized: "Choose from Library"), systemImage: "photo.on.rectangle")
                    }
                } label: {
                    Image(systemName: "camera")
                        .font(.system(size: 20)).foregroundStyle(.white.opacity(0.5))
                }
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
                (recognizer.isRecording || viewModel.isVoiceArmed || viewModel.isImageArmed) ? AppColor.pink.opacity(0.6) : .white.opacity(0.1),
                lineWidth: (viewModel.isVoiceArmed || viewModel.isImageArmed) ? 2 : 1
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

    /// Mikrofon: kaydı başlat/durdur. ARTIK OTOMATIK GÖNDERMEZ — durunca
    /// review aşamasına geçer (bkz. VoiceRecordingOverlay Cancel/Send).
    private func toggleRecording() {
        if recognizer.isRecording {
            recognizer.stop()
            isReviewingVoice = true
        } else {
            Task {
                if !recognizer.authorized { await recognizer.requestAuthorization() }
                guard recognizer.authorized else {
                    viewModel.errorMessage = String(localized: "Microphone & speech recognition access needed.")
                    return
                }
                if !recognizer.start() {
                    viewModel.errorMessage = String(localized: "Couldn't start recording.")
                }
            }
        }
    }

    /// Overlay'in Cancel düğmesi — kaydı at, gönderme.
    private func cancelRecording() {
        recognizer.cancel()
        isReviewingVoice = false
    }

    /// Overlay'in Send düğmesi — kayıt hâlâ sürüyorsa önce durdurur, sonra
    /// transkript + ses dosyasını `sendUserVoice`e verir (bkz. ChatViewModel).
    private func sendRecordedVoice() {
        if recognizer.isRecording { recognizer.stop() }
        isReviewingVoice = false
        guard let url = recognizer.recordedFileURL else { return }
        viewModel.sendUserVoice(transcript: recognizer.transcript, audioURL: url)
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
    var onTapImage: ((URL) -> Void)? = nil
    var onTapLocalImage: ((UIImage) -> Void)? = nil

    /// Her fotoğraf balonu ilk halde bulanık gelir + "Tap to view" ister —
    /// bu ilk dokunuş sadece bulanıklığı açar (tam ekrana gitmez); balon zaten
    /// açıkken tekrar dokunmak eskisi gibi tam ekranı açar (`onTapImage`).
    @State private var imageRevealed = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if message.isUser { Spacer(minLength: 50) }

            if showsTimestamp, message.isUser {
                timestampLabel
            }

            if message.isVoice {
                VoiceMessageBubble(message: message, isUser: message.isUser, isPlaying: isVoicePlaying, onTap: { onPlayVoice?() })
            } else if let localPath = message.localImagePath,
                      let localImage = UserPhotoStore.loadUserPhoto(relativePath: localPath) {
                // Kullanıcının BOTA gönderdiği kendi fotoğrafı — hiç yüklenmedi,
                // sadece cihazda (bkz. UserPhotoStore). CachedImage/ImageCache KULLANILMAZ.
                ZStack(alignment: .bottomLeading) {
                    Image(uiImage: localImage)
                        .resizable().scaledToFill()
                        .frame(width: 220, height: 260)
                        .clipped()
                    if !message.content.isEmpty {
                        Text(message.content)
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.black.opacity(0.45))
                    }
                }
                .frame(width: 220, height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1), lineWidth: 1))
                .onTapGesture { onTapLocalImage?(localImage) }
            } else if let imageURL = message.imageURL {
                // Foto mesajı (kızın gönderdiği fotoğraf) — WhatsApp tarzı KÜÇÜK
                // önizleme kutusu: 9:16 üretilen fotoğrafın tamamı burada
                // gösterilmiyor (kırpılıyor, ASLA gerilmiyor — scaledToFill +
                // clipped), tam hâli sadece tam ekran görünümde (onTapImage).
                // İlk gelişte bulanık + "Tap to view" — ilk dokunuş sadece
                // bulanıklığı açar, sonraki dokunuş tam ekranı açar.
                ZStack {
                    CachedImage(url: imageURL) { img in
                        img.resizable().scaledToFill()
                    } placeholder: { AppColor.card }
                    .frame(width: 220, height: 260)
                    .clipped()
                    .blur(radius: imageRevealed ? 0 : 26)

                    if !imageRevealed {
                        Color.black.opacity(0.25)
                        VStack(spacing: 6) {
                            Text("👀").font(.system(size: 30))
                            Text("Tap to view")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: 220, height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1), lineWidth: 1))
                .onTapGesture {
                    if imageRevealed {
                        onTapImage?(imageURL)
                    } else {
                        withAnimation(.easeOut(duration: 0.3)) { imageRevealed = true }
                    }
                }
            } else {
                Text(message.content)
                    .font(.system(size: 15))
                    .foregroundStyle(message.isUser ? AppColor.bg : .white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background {
                        if message.isUser {
                            AppColor.amber
                        } else {
                            AppColor.card
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
        .background(AppColor.card)
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

/// Just a loading bar — no icon, no "Generating photo…" text (product
/// decision: the photo itself arrives blurred behind a "Tap to view" prompt,
/// see `ChatBubble`'s `imageURL` case, so this indicator doesn't need to
/// announce anything either).
private struct ImagePendingIndicator: View {
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(AppColor.card)
                Capsule().fill(AppColor.pink)
                    .frame(width: geo.size.width * 0.4)
                    .offset(x: sweep ? geo.size.width * 0.6 : -geo.size.width * 0.4)
            }
        }
        .frame(width: 160, height: 6)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                sweep = true
            }
        }
    }
}

// MARK: - Foto tam ekran görüntüleyici

private struct FullscreenImageView: View {
    let url: URL
    let onDismiss: () -> Void
    let onDownloaded: () -> Void

    @State private var saveMessage: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            CachedImage(url: url) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                ProgressView().tint(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture { onDismiss() }

            HStack(spacing: 10) {
                Button(action: downloadImage) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.5), in: Circle())
                }
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.5), in: Circle())
                }
            }
            .padding(16)

            if let saveMessage {
                Text(saveMessage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.7), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 40)
                    .allowsHitTesting(false)
            }
        }
    }

    private func downloadImage() {
        guard let image = ImageCache.shared.image(for: url) else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else {
                    showSaveMessage("Photo access needed to save")
                    return
                }
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                } completionHandler: { success, _ in
                    DispatchQueue.main.async {
                        if success {
                            showSaveMessage("Saved to Photos")
                            onDownloaded()
                        } else {
                            showSaveMessage("Couldn't save photo")
                        }
                    }
                }
            }
        }
    }

    private func showSaveMessage(_ text: String) {
        saveMessage = text
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            saveMessage = nil
        }
    }
}

// MARK: - Kullanıcının kendi fotoğrafı için tam ekran (yerel, indirme yok — zaten cihazda)

private struct LocalImageFullscreenView: View {
    let image: UIImage
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture { onDismiss() }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .padding(16)
        }
    }
}

// MARK: - Kamera yakalama (UIImagePickerController sarmalayıcı — SwiftUI'de yerli canlı kamera view yok)

private struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            } else {
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}

// MARK: - Fotoğraf gönderme öncesi tam ekran review (fotoğraf + opsiyonel caption + Send/Cancel)

private struct PhotoReviewView: View {
    let image: UIImage
    @Binding var caption: String
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 20)).foregroundStyle(.white.opacity(0.5))
                    TextField("", text: $caption,
                              prompt: Text(String(localized: "Add a caption…")).foregroundColor(.white.opacity(0.4)),
                              axis: .vertical)
                        .foregroundStyle(.white)
                        .lineLimit(1...3)
                        .tint(AppColor.pink)
                }
                .padding(.horizontal, 14).frame(minHeight: 46)
                .background(.white.opacity(0.12), in: Capsule())
                .padding(.horizontal, 16)

                HStack {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(.white.opacity(0.15), in: Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button(action: onSend) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(
                                LinearGradient(colors: [AppColor.pink, AppColor.amber],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: Circle()
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Sesli mesaj kaydı overlay'i ("wavy imitator" + timer + Cancel/Send)

private struct VoiceRecordingOverlay: View {
    let isRecording: Bool
    let onCancel: () -> Void
    let onSend: () -> Void

    @State private var elapsed = 0
    @State private var animating = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 3) {
                ForEach(0..<24, id: \.self) { i in
                    Capsule()
                        .fill(AppColor.pink.opacity(isRecording ? 0.9 : 0.5))
                        .frame(width: 3, height: animating ? barHeight(i) : 6)
                        .animation(
                            .easeInOut(duration: 0.4).repeatForever().delay(Double(i % 6) * 0.06),
                            value: animating
                        )
                }
            }
            .frame(maxWidth: .infinity)

            Text(String(format: "%d:%02d", elapsed / 60, elapsed % 60))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))

            Button(action: onSend) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        LinearGradient(colors: [AppColor.pink, AppColor.amber],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppColor.card.opacity(0.9))
        .onAppear { animating = true }
        .onReceive(timer) { _ in if isRecording { elapsed += 1 } }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        [8, 16, 22, 12, 18, 10][i % 6]
    }
}
