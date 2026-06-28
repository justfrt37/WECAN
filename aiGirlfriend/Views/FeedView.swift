//
//  FeedView.swift
//  Ana feed: dikey sayfalanan, tam ekran karakter kartları.
//  Tasarım: AIGUI .pen "Feed" ekranı.
//

import SwiftUI

struct FeedView: View {
    @Environment(CharacterStore.self) private var store
    @State private var segment = 1   // 0: Senin için, 1: Keşfet
    @State private var scrolledID: UUID?

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(store.characters) { character in
                        FeedCard(
                            character: character,
                            segment: $segment,
                            safeTop: geo.safeAreaInsets.top,
                            safeBottom: geo.safeAreaInsets.bottom
                        )
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(character.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $scrolledID)
            .ignoresSafeArea()
        }
        .background(AppColor.bg)
        .onAppear { if scrolledID == nil { scrolledID = store.characters.first?.id } }
        .onChange(of: scrolledID) { _, newValue in
            store.currentCharacterID = newValue
        }
    }
}

/// Tek bir karakterin tam ekran kartı.
private struct FeedCard: View {
    let character: Character
    @Binding var segment: Int
    let safeTop: CGFloat
    let safeBottom: CGFloat

    @State private var showGallery = false
    @State private var showProfile = false

    private let tabBarSpace: CGFloat = 72

    var body: some View {
        // Taban Color.clear: boyut yalnızca dıştaki containerRelativeFrame'den
        // gelir. Foto bir overlay olarak gelir; kendi doğal boyutuyla layout'u
        // asla şişiremez (scaledToFill inflate sorununu önler).
        Color.clear
            // Büyük foto (splash'te cache'lendi → anında gösterilir)
            .overlay {
                CachedImage(url: character.photoURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallbackArt
                }
            }
            .clipped()
            // Alt karartma gradyanı
            .overlay {
                LinearGradient(
                    colors: [.clear, AppColor.bg.opacity(0.95)],
                    startPoint: .center, endPoint: .bottom
                )
            }
        // İçerik katmanları — overlay hizalama ile (flex taşması olmaz)
        .overlay(alignment: .top) {
            segmented
                .padding(.horizontal, 36)
                .padding(.top, safeTop + 12)
        }
        .overlay(alignment: .bottomLeading) {
            profileInfo
                .frame(maxWidth: 240, alignment: .leading)
                .padding(.leading, 16)
                .padding(.bottom, safeBottom + tabBarSpace + 14)
        }
        .overlay(alignment: .bottomTrailing) {
            actionColumn
                .padding(.trailing, 16)
                .padding(.bottom, safeBottom + tabBarSpace + 14)
        }
        .fullScreenCover(isPresented: $showGallery) {
            GalleryView(character: character)
        }
        .fullScreenCover(isPresented: $showProfile) {
            CharacterProfileView(character: character)
        }
    }

    // MARK: Üst segmented

    private var segmented: some View {
        HStack(spacing: 0) {
            segmentButton(title: "Senin için", index: 0)
            segmentButton(title: "Keşfet", index: 1)
        }
        .padding(4)
        .background(AppColor.bg.opacity(0.65), in: RoundedRectangle(cornerRadius: 21))
        .overlay(
            RoundedRectangle(cornerRadius: 21).strokeBorder(.white.opacity(0.1), lineWidth: 1)
        )
        .frame(height: 42)
    }

    private func segmentButton(title: String, index: Int) -> some View {
        let active = segment == index
        return Button {
            segment = index
        } label: {
            Text(title)
                .font(.system(size: 14, weight: active ? .bold : .semibold))
                .foregroundStyle(active ? AppColor.bg : Color.white.opacity(0.6))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(active ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    // MARK: Sol alt — profil bilgisi

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

    // MARK: Sağ alt — aksiyonlar

    private var actionColumn: some View {
        VStack(spacing: 16) {
            actionButton(icon: "photo.fill", label: "Galeri") { showGallery = true }
            NavigationLink(value: character) {
                actionLabelStack(icon: "bubble.left.and.bubble.right.fill", label: "Sohbet")
            }
            .buttonStyle(.plain)
        }
    }

    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            actionLabelStack(icon: icon, label: label)
        }
        .buttonStyle(.plain)
    }

    private func actionLabelStack(icon: String, label: String) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(.white.opacity(0.92))
                    .frame(width: 44, height: 44)
                    .shadow(color: AppColor.bg.opacity(0.4), radius: 8, y: 6)
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(AppColor.bg)
            }
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
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

#Preview {
    FeedView()
        .environment(CharacterStore())
}
