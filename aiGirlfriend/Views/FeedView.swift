//
//  FeedView.swift
//  Keşfet sekmesi — Tinder tarzı sağ/sol kaydır.
//

import SwiftUI

struct FeedView: View {
    @Environment(CharacterStore.self) private var store
    @State private var currentIndex = 0
    @State private var dragOffset = CGSize.zero
    @State private var showTutorial = !UserDefaultsManager.shared.hasSeenSwipeTutorial

    /// Zaten sohbete başlanmış (yerel bir konuşma kaydı olan) karakterler
    /// Discover'da tekrar gösterilmez — aynı tanım NotificationScheduler'ın
    /// Liked You uygunluk kontrolüyle birebir aynı (bkz. LikedByStore).
    private var characters: [Character] {
        // Yalnızca backend'den gelen (store.characters) karakterler — sahte/dummy
        // feed kaldırıldı (bkz. kullanıcı talebi: "backende ne geliyorsa onu göster").
        store.characters.filter {
            !BlockedCharactersStore.isBlocked($0.id) &&
            !PassedCharactersStore.isPassed($0.id) &&
            LocalConversationStore.shared.load(for: $0.id) == nil
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                AppColor.bg.ignoresSafeArea()

                if !characters.isEmpty {
                    // Alttaki kart (sonraki)
                    let nextIdx = (currentIndex + 1) % characters.count
                    FeedCard(
                        character: characters[nextIdx],
                        safeTop: geo.safeAreaInsets.top,
                        safeBottom: geo.safeAreaInsets.bottom
                    )
                    .id(characters[nextIdx].id)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(nextCardScale)
                    .allowsHitTesting(false)

                    // Üstteki kart (geçerli)
                    ZStack {
                        FeedCard(
                            character: characters[currentIndex],
                            safeTop: geo.safeAreaInsets.top,
                            safeBottom: geo.safeAreaInsets.bottom
                        )
                        .id(characters[currentIndex].id)
                        .frame(width: geo.size.width, height: geo.size.height)

                        likeOverlay.opacity(likeOpacity)
                        nopeOverlay.opacity(nopeOpacity)
                    }
                    .offset(x: dragOffset.width, y: 0)
                    .rotationEffect(.degrees(Double(dragOffset.width) / 22), anchor: .bottom)
                    .gesture(
                        DragGesture(minimumDistance: 10)
                            .onChanged { v in
                                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                                dragOffset = CGSize(width: v.translation.width, height: 0)
                            }
                            .onEnded { v in
                                guard abs(v.translation.width) > abs(v.translation.height) else {
                                    withAnimation(.spring()) { dragOffset = .zero }
                                    return
                                }
                                handleSwipe(v.translation, w: geo.size.width)
                            }
                    )
                } else {
                    emptyState
                }

                if showTutorial {
                    SwipeTutorialOverlay {
                        UserDefaultsManager.shared.hasSeenSwipeTutorial = true
                        showTutorial = false
                    }
                }

            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .background(AppColor.bg)
        .onAppear {
            currentIndex = 0
            store.currentCharacterID = characters.first?.id
        }
        .onChange(of: characters) { _, chars in
            if currentIndex >= chars.count { currentIndex = 0 }
            store.currentCharacterID = chars.isEmpty ? nil : chars[currentIndex].id
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 50))
                .foregroundStyle(AppColor.pink.opacity(0.85))
            Text("You're all caught up!")
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text("You've started chatting with everyone in Discover. Check back later for new people.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    // MARK: Hesaplamalar

    private var swipeProgress: CGFloat {
        min(abs(dragOffset.width) / 120, 1)
    }

    private var nextCardScale: CGFloat { 0.93 + 0.07 * swipeProgress }

    private var likeOpacity: Double {
        dragOffset.width > 20 ? min(Double(dragOffset.width - 20) / 80, 1) : 0
    }

    private var nopeOpacity: Double {
        dragOffset.width < -20 ? min(Double(-dragOffset.width - 20) / 80, 1) : 0
    }

    // MARK: Overlay'ler

    private var likeOverlay: some View {
        VStack {
            HStack {
                swipeBadge(text: "LIKE", emoji: "🔥", color: Color(hex: 0x2ECC71), rotation: -18)
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 120)
            Spacer()
        }
    }

    private var nopeOverlay: some View {
        VStack {
            HStack {
                Spacer()
                swipeBadge(text: "NOPE", emoji: "🙅", color: Color(hex: 0xFF4757), rotation: 18)
            }
            .padding(.horizontal, 28)
            .padding(.top, 120)
            Spacer()
        }
    }

    private func swipeBadge(text: LocalizedStringKey, emoji: String, color: Color, rotation: Double) -> some View {
        HStack(spacing: 6) {
            Text(emoji)
                .font(.system(size: 24))
            Text(text)
                .font(.system(size: 26, weight: .black))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(color, lineWidth: 3.5)
        )
        .rotationEffect(.degrees(rotation))
    }

    // MARK: Swipe mantığı

    private func handleSwipe(_ t: CGSize, w: CGFloat) {
        let threshold: CGFloat = 100
        if abs(t.width) > threshold {
            let dir: CGFloat = t.width > 0 ? 1 : -1
            let current = characters.indices.contains(currentIndex) ? characters[currentIndex] : nil
            withAnimation(.easeOut(duration: 0.35)) {
                dragOffset = CGSize(width: dir * w * 1.6, height: t.height * 0.3)
            }
            if dir == 1, let current {
                // "Tanışmak ister misin?" onayı KALDIRILDI — beğeninde doğrudan sohbete git.
                store.pendingMeetRequest = MeetRequest(character: current, prefillText: IcebreakerPool.next())
            } else if dir == -1, let current {
                // Kart hemen `characters`ten düşsün (PassedCharactersStore
                // filtreye giriyor) — önceden HİÇBİR yere kaydedilmiyordu,
                // "nope" görsel olarak ilerliyordu ama karakter asla
                // kaybolmuyordu (deste döngüsünde tekrar tekrar çıkıyordu;
                // tek karakter kalmışsa hep AYNI kart görünüyordu).
                PassedCharactersStore.pass(current.id)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
                dragOffset = .zero
                guard !characters.isEmpty else { return }
                // Beğenide (dir==1) kart hâlâ destede — bir sonrakine geç.
                // Nope'ta (dir==-1) kart zaten listeden düştü, aynı index
                // artık bir sonraki karta işaret ediyor — TEKRAR ilerletme
                // (ilerletirse bir kart atlanır).
                if dir == 1 {
                    currentIndex = (currentIndex + 1) % characters.count
                } else if currentIndex >= characters.count {
                    currentIndex = 0
                }
                store.currentCharacterID = characters[currentIndex].id
            }
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                dragOffset = .zero
            }
        }
    }
}

/// Tek bir karakterin tam ekran kartı.
private struct FeedCard: View {
    let character: Character
    let safeTop: CGFloat
    let safeBottom: CGFloat

    @State private var showGallery = false
    @State private var showProfile = false

    private let tabBarSpace: CGFloat = 72

    var body: some View {
        Color.clear
            // Üstten hizala: scaledToFill taşan kısmı ALTTAN kırpsın, böylece
            // yüz (üst kısım) tam görünür, ortadan kırpıp yüzü kesmez.
            .overlay(alignment: .top) {
                CachedImage(url: character.photoURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallbackArt
                }
            }
            .clipped()
            .overlay {
                LinearGradient(
                    colors: [.clear, AppColor.bg.opacity(0.95)],
                    startPoint: .center, endPoint: .bottom
                )
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 14) {
                    profileInfo
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)

                    actionRow
                        .padding(.horizontal, 16)
                }
                .padding(.bottom, safeBottom + tabBarSpace + 35)
            }
            .fullScreenCover(isPresented: $showGallery) {
                GalleryView(character: character)
            }
            .fullScreenCover(isPresented: $showProfile) {
                CharacterProfileView(character: character)
            }
    }

    // MARK: Profil bilgisi

    private var profileInfo: some View {
        Button { showProfile = true } label: {
            profileInfoContent
        }
        .buttonStyle(.plain)
    }

    private var profileInfoContent: some View {
        HStack(alignment: .center, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(character.nameWithAge)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)

                if let loc = character.locationText {
                    Label {
                        Text(loc).font(.system(size: 12, weight: .medium))
                    } icon: {
                        Image(systemName: "mappin.and.ellipse").font(.system(size: 11))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                }

                if let job = character.profession {
                    Label {
                        Text(job).font(.system(size: 11, weight: .semibold))
                    } icon: {
                        Image(systemName: "briefcase.fill").font(.system(size: 11))
                    }
                    .foregroundStyle(AppColor.pinkSoft)
                }
            }
            Spacer()
        }
    }

    private var avatar: some View {
        CachedImage(url: character.avatarURL ?? character.photoURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            AppColor.pink
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
    }

    // MARK: Aksiyon satırı — Galeri / Mesajlaş

    private var actionRow: some View {
        HStack(spacing: 12) {
            bigActionButton(icon: "photo.fill", label: "Gallery") { showGallery = true }

            NavigationLink(value: character) {
                bigActionLabel(icon: "bubble.left.and.bubble.right.fill", label: "Chat")
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    private func bigActionButton(icon: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            bigActionLabel(icon: icon, label: label)
        }
        .buttonStyle(.plain)
    }

    private func bigActionLabel(icon: String, label: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
            Text(label)
                .font(.system(size: 15, weight: .bold))
        }
        .foregroundStyle(AppColor.bg)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(Color.white.opacity(0.95), in: RoundedRectangle(cornerRadius: 26))
        .shadow(color: AppColor.bg.opacity(0.4), radius: 8, y: 6)
    }

    private var fallbackArt: some View {
        ZStack {
            LinearGradient(colors: [AppColor.bg2, AppColor.card],
                           startPoint: .top, endPoint: .bottom)
            Image(systemName: character.avatarSymbol)
                .font(.system(size: 80))
                .foregroundStyle(.white.opacity(0.3))
        }
    }
}

/// İlk kullanımda gösterilen, sağa/sola kaydırmayı öğreten katman.
/// Ekranın herhangi bir yerine dokununca kapanır, bir daha gösterilmez.
private struct SwipeTutorialOverlay: View {
    let onDismiss: () -> Void
    @State private var handOffset: CGFloat = -40

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                HStack(spacing: 16) {
                    tutorialBadge(emoji: "🙅", text: "NOPE", caption: "Swipe left: pass")
                    tutorialBadge(emoji: "🔥", text: "LIKE", caption: "Swipe right: like")
                }

                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: handOffset)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                            handOffset = 40
                        }
                    }

                Text("Tap anywhere to continue")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))

                Spacer()
            }
            .padding(.horizontal, 32)
        }
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .transition(.opacity)
    }

    private func tutorialBadge(emoji: String, text: LocalizedStringKey, caption: LocalizedStringKey) -> some View {
        VStack(spacing: 6) {
            Text(emoji).font(.system(size: 30))
            Text(text)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(.white)
            Text(caption)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Beğeniden sonra "tanışmak ister misin?" onayı — evet derse sohbete geçer,
/// hazır bir açılış mesajı ("prefillText") mesaj kutusuna önceden yazılır.
private struct MeetConfirmOverlay: View {
    let character: Character
    let onYes: () -> Void
    let onNo: () -> Void

    @State private var dontShowAgain = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()

            VStack(spacing: 18) {
                Text("Want to meet \(character.name)?")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button {
                        persistPreference()
                        onNo()
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        persistPreference()
                        onYes()
                    } label: {
                        Text("Let's meet")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background(LinearGradient(colors: [AppColor.pink, AppColor.amber],
                                                       startPoint: .leading, endPoint: .trailing), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    dontShowAgain.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: dontShowAgain ? "checkmark.square.fill" : "square")
                            .foregroundStyle(dontShowAgain ? AppColor.pink : .white.opacity(0.5))
                        Text("Don't show again")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .background(AppColor.bg2, in: RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal, 32)
        }
        .transition(.opacity)
    }

    private func persistPreference() {
        if dontShowAgain { UserDefaultsManager.shared.skipMeetConfirm = true }
    }
}

#Preview {
    FeedView()
        .environment(CharacterStore())
}
