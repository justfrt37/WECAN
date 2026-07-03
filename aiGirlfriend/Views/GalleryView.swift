//
//  GalleryView.swift
//  Galeri sheet — fullscreen.
//  Tasarım: AIGUI .pen "Lumi - Gallery Sheet".
//

import SwiftUI

struct GalleryView: View {
    let character: Character
    @Environment(\.dismiss) private var dismiss
    @State private var showPaywall = false

    // Kilitli grid için galeri resimleri (şimdilik feed fotosu tekrar eder).
    private var lockedImages: [URL] {
        let base = character.galleryURLs.isEmpty
            ? [character.photoURL].compactMap { $0 }
            : character.galleryURLs
        guard !base.isEmpty else { return [] }
        return (0..<8).map { base[$0 % base.count] }
    }

    private let columns = [GridItem(.flexible(), spacing: 13),
                           GridItem(.flexible(), spacing: 13)]

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [AppColor.bg, AppColor.bg2, AppColor.bg],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    heroCard
                    section
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 110)
            }

            proCTA
        }
        .sheet(isPresented: $showPaywall) { PaywallHostView() }
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

    // MARK: Kilitli foto grid

    private var section: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(hex: 0xFFA726))
                    Text("More Photos")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
                Spacer()
                Text("\(lockedImages.count) photos")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }

            LazyVGrid(columns: columns, spacing: 13) {
                ForEach(Array(lockedImages.enumerated()), id: \.offset) { _, url in
                    lockedTile(url)
                }
            }
        }
    }

    private func lockedTile(_ url: URL) -> some View {
        ZStack {
            CachedImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                AppColor.card
            }
            .frame(height: 200)
            .frame(maxWidth: .infinity)
            .clipped()
            .blur(radius: 18)

            Color.black.opacity(0.25)

            Image(systemName: "lock.fill")
                .font(.system(size: 34))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: PRO CTA

    private var proCTA: some View {
        Button { showPaywall = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "crown.fill").font(.system(size: 16))
                Text("Upgrade to PRO · See All Photos")
                    .font(.system(size: 15, weight: .heavy))
            }
            .foregroundStyle(Color(hex: 0x1A0826))
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                LinearGradient(colors: [Color(hex: 0xFFC76B), Color(hex: 0xFFA726), Color(hex: 0xFF8A00)],
                               startPoint: .top, endPoint: .bottom),
                in: Capsule()
            )
            .shadow(color: Color(hex: 0xFFA726).opacity(0.5), radius: 16, y: 8)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [.clear, AppColor.bg.opacity(0.9), AppColor.bg],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        )
    }
}

#Preview {
    GalleryView(character: Character.samples[0])
}
