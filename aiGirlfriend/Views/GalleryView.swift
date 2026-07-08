//
//  GalleryView.swift
//  Galeri sheet — fullscreen.
//  Tasarım: AIGUI .pen "Lumi - Gallery Sheet".
//

import SwiftUI

struct GalleryView: View {
    let character: Character
    @Environment(\.dismiss) private var dismiss
    @State private var yourPhotos: [URL] = []

    private let columns = [GridItem(.flexible(), spacing: 13),
                           GridItem(.flexible(), spacing: 13)]

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [AppColor.bg, AppColor.bg2, AppColor.bg],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            // Hazır (pre-made) galeri fotoğrafları BURADA gösterilmiyor —
            // SADECE karakter profilinin ("about me") hero carousel'inde,
            // PRO olmayanlar için bulanık/kilitli olarak (bkz.
            // CharacterProfileView.hero). Burası tamamen kullanıcının
            // KENDİ ürettiği fotoğraflar için — hepsi açık gösterilir.
            ScrollView {
                VStack(spacing: 24) {
                    heroCard
                    yourPhotosSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .task {
            yourPhotos = (try? await GeneratedPhotoService().fetch(characterId: character.id)) ?? []
        }
    }

    // MARK: Hero kart

    private var heroCard: some View {
        ZStack(alignment: .bottomLeading) {
            CachedImage(url: character.photoURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                AppColor.card
            }
            .frame(height: 380)
            .frame(maxWidth: .infinity)
            .clipped()

            LinearGradient(colors: [.clear, AppColor.bg.opacity(0.6), AppColor.bg.opacity(0.95)],
                           startPoint: .center, endPoint: .bottom)

            // İsim + meslek · konum
            VStack(alignment: .leading, spacing: 6) {
                Text(character.nameWithAge)
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(.white)
                HStack(spacing: 8) {
                    if let prof = character.profession {
                        Text(prof).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    Circle().fill(AppColor.pink).frame(width: 4, height: 4)
                    if let loc = character.locationText {
                        Text(loc).font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .padding(20)
        }
        .frame(height: 380)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .topLeading) { aiBadge.padding(20) }
        .overlay(alignment: .topTrailing) { headerButtons.padding(16) }
    }

    private var aiBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles").font(.system(size: 10))
            Text("AI Companion").font(.system(size: 10, weight: .bold)).tracking(0.4)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(AppColor.pink, in: Capsule())
    }

    private var headerButtons: some View {
        HStack(spacing: 10) {
            circleButton("ellipsis") { }
            circleButton("xmark") { dismiss() }
        }
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(AppColor.bg.opacity(0.7), in: Circle())
        }
    }

    // MARK: Senin Fotoğrafların

    private var yourPhotosSection: some View {
        // Header always shows (even with zero photos) — only the body below
        // switches between the grid and the empty state, per product ask.
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15))
                    .foregroundStyle(AppColor.pink)
                Text("Your Photos")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(yourPhotos.count) photos")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }

            if yourPhotos.isEmpty {
                noPhotosYetState
            } else {
                LazyVGrid(columns: columns, spacing: 13) {
                    ForEach(yourPhotos, id: \.self) { url in
                        CachedImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            AppColor.card
                        }
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }
        }
    }

    private var noPhotosYetState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.3))
            Text("No photos yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            Text("Ask them to send you a photo in chat")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(AppColor.card.opacity(0.4), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

}

#Preview {
    GalleryView(character: Character.samples[0])
}
