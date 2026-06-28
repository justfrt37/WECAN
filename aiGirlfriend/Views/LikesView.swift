//
//  LikesView.swift
//  "Beğeniler" sekmesi — seni beğenen karakterler.
//  Tasarım: AIGUI .pen "Lumi - Beğeniler (Premium)".
//  PRO değilse kartlar blur'lu; PRO ise görünür. Şimdilik PRO açık (görünür).
//

import SwiftUI

struct LikesView: View {
    @Environment(CharacterStore.self) private var store

    /// Şimdilik PRO açık kabul ediliyor (kızlar direkt görünür).
    @State private var isPro = true
    @State private var profileCharacter: Character?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    /// Seni beğenen karakterler (şimdilik katalogdan).
    private var likers: [Character] { store.characters }

    var body: some View {
        ZStack {
            LinearGradient(colors: [AppColor.bg, AppColor.bg2, AppColor.bg],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        infoRow
                        grid
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 100)
                }
                .scrollIndicators(.hidden)
            }
        }
        .fullScreenCover(item: $profileCharacter) { CharacterProfileView(character: $0) }
    }

    private var header: some View {
        HStack {
            Text("Seni Beğenenler")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            Image(systemName: "heart.fill")
                .foregroundStyle(AppColor.pink)
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.08), in: Circle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var infoRow: some View {
        HStack(spacing: 12) {
            Label("\(likers.count) kişi seni beğendi", systemImage: "heart.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppColor.pink)
            Label(isPro ? "Lumi PRO aktif" : "PRO değil", systemImage: "crown.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: 0xFFB938))
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(Array(likers.enumerated()), id: \.element.id) { idx, c in
                Button {
                    if isPro { profileCharacter = c }
                } label: {
                    LikeCard(character: c, locked: !isPro,
                             badge: idx == 0 ? "NEW" : (idx == 1 ? "PRO" : nil))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct LikeCard: View {
    let character: Character
    let locked: Bool
    let badge: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CachedImage(url: character.photoURL) { img in
                img.resizable().scaledToFill()
            } placeholder: { AppColor.card }
            .frame(maxWidth: .infinity).frame(height: 200)
            .clipped()
            .blur(radius: locked ? 22 : 0)

            LinearGradient(colors: [.clear, .black.opacity(0.85)],
                           startPoint: .center, endPoint: .bottom)

            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 32)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(character.nameWithAge)
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    Text([character.profession, character.category].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                }
                .padding(12)
            }
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topLeading) {
            if let badge {
                Text(badge)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(badge == "PRO" ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xFFB938), Color(hex: 0xFF8E3C)], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(AppColor.pink),
                                in: Capsule())
                    .padding(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "heart.fill")
                .font(.system(size: 16)).foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(AppColor.pink, in: Circle())
                .padding(10)
        }
    }
}

#Preview {
    LikesView().environment(CharacterStore())
}
