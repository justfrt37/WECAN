//
//  ChatView.swift
//  Sohbet ekranı — "Lumi - Chat Conversation" tasarımı.
//

import SwiftUI
import Photos
import PhotosUI
import UIKit

/// Mesaj listesinin alt kenarının, kaydırma görünür alanındaki Y konumu —
/// "kullanıcı dibe yakın mı" tespitinde kullanılır (bkz. ChatView.messagesList).
private struct ChatBottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ChatView: View {
    @State private var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(CharacterStore.self) private var store
    @Environment(TokenStore.self) private var tokenStore

    @State private var showProfile = false
    @State private var showTokenStore = false
    @State private var addSheetKind: NoteKind?
    @State private var showBlockConfirm = false
    @State private var isBlocked: Bool
    @State private var recognizer = SpeechRecognizer()
    @State private var voice = VoicePlayer()
    @State private var didPrefill = false
    @State private var readyToAutoScroll = false
    /// Kullanıcı listenin DİBİNE yakın mı — yeni mesaj/typing gelince yalnızca
    /// dipteyse otomatik kaydırılır; geçmişe bakmak için yukarı kaydırdıysa dibe
    /// ZORLANMAZ (yukarı-aşağı zıplama bunun eksikliğindendi).
    @State private var isNearBottom = true
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
        .fullScreenCover(isPresented: $showTokenStore) {
            TokenStoreView(tokenStore: tokenStore)
        }
        // Token yetmeyince (PRO kullanıcı) VM bunu açar — uyarı yerine coin mağazası.
        .fullScreenCover(isPresented: $viewModel.showTokenStore) {
            TokenStoreView(tokenStore: tokenStore)
        }
        .fullScreenCover(isPresented: $showProfile) {
            CharacterProfileView(character: viewModel.character, showsChatButton: false)
        }
        // PRO gerektiren her yerde onboarding paywall'ı (alttan fullscreen) açılır.
        .fullScreenCover(isPresented: $viewModel.showPaywall) { OnboardingPaywallView() }
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
            // Yukarıdan inen "seviye arttı" banner'ı KALDIRILDI (bkz. kullanıcı
            // talebi). Sadece avatar halkasında kısa bir parlama kalıyor.
            guard newValue != nil else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { avatarPulse = true }
            Task {
                try? await Task.sleep(nanoseconds: 2_800_000_000)
                withAnimation(.easeInOut(duration: 0.4)) { avatarPulse = false }
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
                                        // Tek satır; uzunsa "…" değil, font küçülerek sığar (alta kaymaz).
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                }
                            }
                            Text("Level \(viewModel.relationshipLevel) · \(viewModel.relationshipStage)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppColor.pinkSoft)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                }
                .buttonStyle(.plain)
                // İsim/durum bloğuna kalan genişliği ver → uzun aşama isimleri
                // alta sarmak yerine font küçülterek tek satırda sığar.
                .frame(maxWidth: .infinity, alignment: .leading)

                // PRO değilse coin (kalp) rozeti yerine PRO butonu; PRO ise coin
                // rozeti. Ayarlar hep yanında (bkz. kullanıcı talebi). Sohbette
                // global overlay rozeti gizli (bkz. MainTabView).
                if PurchaseService.shared.isPro {
                    TokenBadge(tokenStore: tokenStore) { showTokenStore = true }
                } else {
                    chatProButton
                }
                headerButton("gearshape.fill", menu: true)
            }
        }
        .padding(.leading, 14)
        // Ayarlar (gear) butonu EN SAĞDA — coin rozetinin SAĞINDA, aynı hizada.
        // Coin, MainTabView'ın overlay'ında sohbetteyken sola kaydırılır (gear'a
        // yer açar, bkz. MainTabView coin overlay trailing padding).
        .padding(.trailing, 14)
        .padding(.vertical, 8)
    }

    /// PRO değilken chat header'ında coin rozeti yerine görünen PRO butonu —
    /// onboarding paywall'ını açar (MainTabView'daki tab-kökü PRO butonuyla aynı).
    private var chatProButton: some View {
        Button { viewModel.showPaywall = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "crown.fill").font(.system(size: 12, weight: .bold))
                Text("PRO").font(.system(size: 13, weight: .heavy))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(
                LinearGradient(colors: [Color(hex: 0xFFAF5C), Color(hex: 0xFF6F61)],
                               startPoint: .leading, endPoint: .trailing),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
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
        GeometryReader { outer in
        ScrollViewReader { proxy in
            ScrollView {
                // VStack (NOT LazyVStack) — kasıtlı. Lazy çizim, görünmeyen
                // satırları ölçmeden bırakıyor, bu da scrollTo/defaultScrollAnchor'ın
                // en alt konumunu TAHMİN etmesine yol açıyordu — foto ağırlıklı/
                // uzun sohbetlerde (bkz. Jasmine, 4-5 foto) tahmin yanlış çıkıp
                // mesajlar görünmez kalıyordu, sadece yukarı kaydırınca ortaya
                // çıkıyordu. Sohbet geçmişi telefon ekranı için zaten sınırlı
                // boyutta (bkz. LocalConversationStore) — hepsini baştan ölçmek ucuz.
                VStack(spacing: 0) {
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
                        }, isVoicePlaying: voice.isPlaying && voice.speakingMessageID == message.id,
                           voiceIsActive: voice.speakingMessageID == message.id,
                           voiceProgress: voice.speakingMessageID == message.id ? voice.playbackProgress : 0,
                           voiceElapsed: voice.speakingMessageID == message.id ? voice.playbackElapsed : 0,
                           onPlayVoice: {
                            // Çalıyorsa duraklat, duraklatılmışsa devam, değilse baştan çal.
                            if let path = message.voiceLocalPath {
                                voice.togglePlay(at: path, id: message.id)
                            }
                        }, onVoiceSeek: { frac in
                            if voice.speakingMessageID == message.id { voice.seek(to: frac) }
                        }, onTapImage: { url in
                            fullscreenImageURL = url
                        }, onTapLocalImage: { image in
                            fullscreenLocalImage = image
                        }, isGeneratingImage: viewModel.generatingImageMessageIDs.contains(message.id),
                           isGeneratingVoice: viewModel.generatingVoiceMessageIDs.contains(message.id),
                           isPreparingVoice: viewModel.preparingVoiceMessageIDs.contains(message.id),
                           onGenerateImage: { viewModel.generatePendingImage(for: message.id) },
                           onGenerateVoice: { viewModel.generatePendingVoice(for: message.id) },
                           characterPhotoURL: viewModel.character.photoURL)
                        .id(message.id)
                        // "Whoosh" girişi — pending foto balonu botun az önce
                        // kendi kararıyla gönderdiği bir şey gibi kaysın/belirsin
                        // (bkz. ChatViewModel.sendImageRequest'teki withAnimation).
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .opacity
                        ))
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
                            // "Yazıyor" balonu zemine fazla yapışmasın — mesajların
                            // 5pt alt boşluğuna ek 4pt (bkz. kullanıcı talebi).
                            .padding(.bottom, 4)
                            .id("typing")
                    }
                }
                .padding(.top, 12)
                // Son mesaj ile zemin arası boşluk AYRI görünmez çapa olarak durur;
                // otomatik-kaydırma buna hizalanır (scrollTo("bottomAnchor")), böylece
                // boşluk "katlanmanın altında" kaybolmaz — özellikle bot mesajında.
                Color.clear.frame(height: 45).id("bottomAnchor")
                }
                // Kısa içerik (ör. ilk mesaj) doğal olarak ÜSTTEN başlar → header'a
                // dayanır. Uzun geçmiş açılışta programatik olarak dibe konumlanır.
                .frame(maxWidth: .infinity, alignment: .top)
                // İçeriğin alt kenarının, görünür alandaki konumunu yayınla.
                .background(
                    GeometryReader { g in
                        Color.clear.preference(
                            key: ChatBottomOffsetKey.self,
                            value: g.frame(in: .named("chatScroll")).maxY
                        )
                    }
                )
            }
            // NOT: defaultScrollAnchor(.bottom) KULLANILMIYOR — yukarı kaydırırken
            // dibe yeniden tutunup titremeye (zıplama) yol açıyordu (bkz. kullanıcı
            // talebi). Onun yerine: açılışta animasyonsuz, yeni mesajda animasyonlu
            // programatik kaydırma — ve yalnızca kullanıcı DİPTEYSE (bkz. isNearBottom).
            .coordinateSpace(name: "chatScroll")
            .scrollIndicators(.hidden)
            .onPreferenceChange(ChatBottomOffsetKey.self) { contentBottomY in
                // İçerik alt kenarı görünür alanın dibine yakınsa "dipte" say.
                // Uzaktaysa (yukarı kaydırılmış) yeni mesaj dibe ZORLAMAZ.
                isNearBottom = contentBottomY <= outer.size.height + 140
            }
            .onChange(of: viewModel.messages.count) {
                guard readyToAutoScroll else {
                    // İlk yükleme (geçmiş): animasyonsuz dibe konumlan.
                    scrollToBottomInstant(proxy)
                    return
                }
                // Kullanıcı geçmişe bakmak için yukarı kaymışsa dibe ZORLAMA.
                if isNearBottom { scrollToBottom(proxy) }
            }
            .onChange(of: viewModel.showsTypingBubble) {
                if readyToAutoScroll && isNearBottom { scrollToBottom(proxy) }
            }
            .onAppear {
                Task {
                    // İçerik otursun; geçmiş varsa animasyonsuz dibe konumlan,
                    // sonra otomatik-kaydırmayı aç.
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    scrollToBottomInstant(proxy)
                    readyToAutoScroll = true
                }
            }
        }
        }
    }

    private func scrollToBottomInstant(_ proxy: ScrollViewProxy) {
        proxy.scrollTo("bottomAnchor", anchor: .bottom)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation {
            // Padding'in ALTINDAki görünmez çapaya hizala — son mesaj/typing
            // balonu 45pt boşlukla birlikte görünür kalsın (bkz. bottomAnchor).
            proxy.scrollTo("bottomAnchor", anchor: .bottom)
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
        // Üst köşeler yuvarlatılır (sol-üst + sağ-üst), alt köşeler düz.
        .background(
            AppColor.card.opacity(0.6),
            in: .rect(topLeadingRadius: 12, topTrailingRadius: 12)
        )
    }

    private func modeButton(icon: String, label: String, isArmed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(isArmed ? AppColor.amber : .white.opacity(0.85))
            .padding(.horizontal, 14).frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(isArmed ? AppColor.amber.opacity(0.15) : .white.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(isArmed ? AppColor.amber.opacity(0.5) : .white.opacity(0.12), lineWidth: 1))
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
    var voiceIsActive: Bool = false
    var voiceProgress: Double = 0
    var voiceElapsed: Double = 0
    var onPlayVoice: (() -> Void)? = nil
    var onVoiceSeek: ((Double) -> Void)? = nil
    var onTapImage: ((URL) -> Void)? = nil
    var onTapLocalImage: ((UIImage) -> Void)? = nil
    var isGeneratingImage: Bool = false
    var isGeneratingVoice: Bool = false
    var isPreparingVoice: Bool = false
    var onGenerateImage: (() -> Void)? = nil
    var onGenerateVoice: (() -> Void)? = nil
    /// Ödeme bekleyen foto balonunun bulanık arka planı — karakterin KENDİ
    /// profil fotoğrafı (bkz. PendingImageBubble), henüz gerçek foto yok.
    var characterPhotoURL: URL? = nil

    /// Her fotoğraf balonu ilk halde bulanık gelir + "Tap to view" ister —
    /// bu ilk dokunuş sadece bulanıklığı açar (tam ekrana gitmez); balon zaten
    /// açıkken tekrar dokunmak eskisi gibi tam ekranı açar (`onTapImage`).
    /// Az önce ödeyip ÜRETTİRDİĞİMİZ bir foto burada zaten `true` başlar —
    /// tekrar bulanıklaştırmak (çifte bulanıklık) kötü UX olurdu (bkz.
    /// ChatViewModel.generatePendingImage'ın hemen sonrası).
    @State private var imageRevealed = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if message.isUser { Spacer(minLength: 50) }

            if showsTimestamp, message.isUser {
                timestampLabel
            }

            if message.isPendingImage {
                PendingImageBubble(backdropURL: characterPhotoURL,
                                    isGenerating: isGeneratingImage,
                                    onTap: { onGenerateImage?() })
            } else if message.isPendingVoice {
                PendingVoiceBubble(isPreparing: isPreparingVoice,
                                    isGenerating: isGeneratingVoice,
                                    onTap: { onGenerateVoice?() })
            } else if message.isVoice {
                VoiceMessageBubble(message: message, isUser: message.isUser, isPlaying: isVoicePlaying,
                                   isActive: voiceIsActive,
                                   progress: voiceProgress, elapsed: voiceElapsed,
                                   onTap: { onPlayVoice?() },
                                   onSeek: { frac in onVoiceSeek?(frac) })
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
                    } placeholder: {
                        // Foto açılırken (henüz yüklenmediyse) progress dönsün.
                        ZStack {
                            AppColor.card
                            ProgressView().tint(.white)
                        }
                    }
                    .frame(width: 220, height: 260)
                    .clipped()
                    .blur(radius: imageRevealed ? 0 : 26)

                    if !imageRevealed {
                        Color.black.opacity(0.25)
                        Text("Tap to view")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

            if !message.isUser { Spacer(minLength: 50) }
        }
        .padding(.horizontal, 16)
        // Az önce (bu oturumda) pending'den üretilmiş bir foto otomatik açık
        // gelsin — kullanıcı zaten ödeyip dokunarak üretti, hemen ardından
        // İKİNCİ bir "tap to view" bulanıklığı görmesi kötü UX olur. Geçmişten
        // yüklenen (hiç pending olmamış) fotolar bu satırı hiç tetiklemez,
        // eski "tap to view" gizlilik bulanıklığını korurlar.
        .onChange(of: message.pendingImagePrompt) { old, new in
            if old != nil && new == nil { imageRevealed = true }
        }
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
                    .fill(AppColor.amber.opacity(0.9))
                    .frame(width: 3, height: animating ? barHeight(i) : 6)
                    .animation(
                        .easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.12),
                        value: animating
                    )
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(AppColor.amber.opacity(0.14))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(AppColor.amber.opacity(0.35), lineWidth: 1))
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
// MARK: - Ödeme bekleyen foto/ses balonları

/// Botun fotoğrafı — ilk halde HİÇ üretilmemiş, sadece tarif metni saklı
/// (bkz. Message.pendingImagePrompt). Bulanık kutu + token maliyeti; dokununca
/// `onTap` (ChatViewModel.generatePendingImage) tetiklenir. Üretim sürerken
/// (`isGenerating`) yükleme çubuğu gösterilir, dokunma devre dışı kalır —
/// bulanıklık görsel CİHAZA TAM İNENE kadar kalkmaz (bkz. ChatViewModel).
/// Aynı bulanıklık/"Tap to view" tasarımı zaten üretilmiş fotoğraflarda
/// kullanılıyor (bkz. ChatBubble'ın imageURL dalı) — burada AYNI görsel dil,
/// arkada gerçek foto yerine karakterin KENDİ profil fotoğrafı bulanık
/// gösteriliyor (henüz üretilmiş bir şey yok). Tek fark: token maliyeti
/// SADECE burada (ödeme bekleyen istek) gösterilir, zaten-üretilmiş foto
/// balonunda hiç yok.
private struct PendingImageBubble: View {
    let backdropURL: URL?
    let isGenerating: Bool
    let onTap: () -> Void

    var body: some View {
        ZStack {
            CachedImage(url: backdropURL) { img in
                img.resizable().scaledToFill()
            } placeholder: { AppColor.card }
            .frame(width: 220, height: 260)
            .clipped()
            .blur(radius: 26)

            Color.black.opacity(0.25)

            if isGenerating {
                ImagePendingIndicator()
            } else {
                // "25 ♥" + "Görmek için dokun" AYNI beyaz dikdörtgen içinde
                // (bkz. kullanıcı talebi). Maliyet üstte, metin altta; hepsi siyah.
                VStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Text("25")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(.black)
                        CoinIcon(size: 14)
                    }
                    Text("Tap to view")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.black)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(width: 220, height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { if !isGenerating { onTap() } }
    }
}

/// Botun sesli mesajı — ilk halde HİÇ üretilmemiş, süresi belirsiz (henüz
/// sentezlenmedi, bkz. Message.pendingVoiceRequest). Dokununca `onTap`
/// (ChatViewModel.generatePendingVoice) tetiklenir.
private struct PendingVoiceBubble: View {
    /// İstekten hemen sonraki ~3 sn "hazırlanıyor" (karakter kaydediyormuş
    /// hissi) — yanıp sönen mikrofon, henüz dokunulamaz (bkz. ChatViewModel
    /// .preparingVoiceMessageIDs).
    let isPreparing: Bool
    let isGenerating: Bool
    let onTap: () -> Void

    /// Sesli mesaj maliyeti (token). Sunucudaki tahsille (voice-message-tts)
    /// aynı — orası kaynak-doğru; burada gösterim için ayna.
    private let coinCost = 12

    /// Hazırlanırken/üretilirken yanıp sönen kayıt ikonu için.
    @State private var blink = false

    var body: some View {
        HStack(spacing: 10) {
            // Öndeki eleman (mikrofon / maliyet rozeti) SABİT genişlikte bir
            // yuvada — kalp rozetine basıp mikrofona geçince balon boyutu
            // DEĞİŞMESİN (bkz. kullanıcı talebi).
            Group {
                if isPreparing || isGenerating {
                    // Kayıt ikonu balonun İÇİNDE yanıp söner (önce ~3 sn hazırlanıyor,
                    // sonra dokununca üretim) — bittiğinde WhatsApp tarzı sesli mesaja
                    // dönüşür (bkz. kullanıcı talebi).
                    Image(systemName: "mic.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(AppColor.pink)
                        .opacity(blink ? 1 : 0.25)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                                blink = true
                            }
                        }
                        // Kilitli aşamada mikrofon kaybolunca sıfırla — satın almaya
                        // basıp üretim başlayınca tekrar görününce yeniden yanıp sönsün.
                        .onDisappear { blink = false }
                } else {
                    // PLAY tuşunun yerinde maliyet rozeti — beyaz zemin, sayı + kalp.
                    HStack(spacing: 3) {
                        Text("\(coinCost)")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(.black)
                        CoinIcon(size: 15)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(.white, in: Capsule())
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .frame(width: 58, alignment: .leading)

            // Dekoratif dalga-formu (soluk, WhatsApp görünümü). Süre YAZISI YOK —
            // süre yalnızca ses açılıp geldiğinde (VoiceMessageBubble) gösterilir
            // (bkz. kullanıcı talebi: "kalp varken sağda süresi görünmesin").
            HStack(spacing: 3) {
                ForEach(0..<14, id: \.self) { _ in
                    Capsule().fill(.white.opacity(0.28)).frame(width: 2.5, height: 10)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppColor.card, in: RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture { if !isGenerating && !isPreparing { onTap() } }
    }
}

private struct ImagePendingIndicator: View {
    var body: some View {
        // Düz bar yerine dönen daire (spinner).
        ProgressView()
            .progressViewStyle(.circular)
            .tint(.white)
            .scaleEffect(1.3)
    }
}

// MARK: - Foto tam ekran görüntüleyici

// MARK: - Yakınlaştırılabilir tam ekran sarmalayıcı (pinch-to-zoom + pan + çift dokunma sıfırlama)

private struct ZoomableView<Content: View>: View {
    let onSingleTap: () -> Void
    @ViewBuilder let content: Content

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 4

    var body: some View {
        content
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = min(max(lastScale * value, minScale), maxScale)
                    }
                    .onEnded { _ in
                        lastScale = scale
                        if scale <= minScale { resetZoom() }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard scale > minScale else { return }
                        offset = CGSize(width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height)
                    }
                    .onEnded { _ in lastOffset = offset }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if scale > minScale { resetZoom() } else { scale = 2; lastScale = 2 }
                }
            }
            .onTapGesture { if scale <= minScale { onSingleTap() } }
    }

    private func resetZoom() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
        }
    }
}

private struct FullscreenImageView: View {
    let url: URL
    let onDismiss: () -> Void
    let onDownloaded: () -> Void

    @State private var saveMessage: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            ZoomableView(onSingleTap: onDismiss) {
                CachedImage(url: url) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
            ZoomableView(onSingleTap: onDismiss) {
                Image(uiImage: image)
                    .resizable().scaledToFit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
