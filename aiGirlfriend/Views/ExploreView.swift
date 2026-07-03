//
//  ExploreView.swift
//  "Tümünü Gör" sekmesi — kategoriye göre tüm karakter kataloğu.
//  Tasarım: AIGUI .pen "Tümünü Gör" ekranı.
//
//  Karakterler Supabase'ten gelir (CharacterStore). Şimdilik kartlar normal
//  (blursuz) gösterilir; PRO kilidi/blur sonra eklenecek.
//

import SwiftUI

struct ExploreView: View {
    @Environment(CharacterStore.self) private var store

    @State private var selectedCategory: ExploreCategory = .all
    @State private var search = ""
    @State private var profileCharacter: Character?
    @State private var showCreate = false

    /// Kategori + arama filtresi uygulanmış liste (engellenenler hariç).
    private var filtered: [Character] {
        store.characters.filter { c in
            guard !BlockedCharactersStore.isBlocked(c.id) else { return false }
            let catOK = selectedCategory == .all || c.category == selectedCategory.rawValue
            let q = search.trimmingCharacters(in: .whitespaces)
            let searchOK = q.isEmpty || c.name.localizedCaseInsensitiveContains(q)
                || (c.profession?.localizedCaseInsensitiveContains(q) ?? false)
            return catOK && searchOK
        }
    }

    private let columns = [GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 16) {
                    searchBar
                    pills
                    proBanner
                    grid
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 96)   // tab bar payı
            }
            .scrollIndicators(.hidden)
        }
        .background(
            LinearGradient(colors: [AppColor.bg, AppColor.bg2, AppColor.bg],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .fullScreenCover(item: $profileCharacter) { character in
            CharacterProfileView(character: character)
        }
        .fullScreenCover(isPresented: $showCreate) {
            CreateCharacterView()
        }
    }

    // MARK: Başlık

    private var header: some View {
        Text("Tümünü Gör")
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
    }

    // MARK: Arama

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.7))
            TextField(
                "",
                text: $search,
                prompt: Text("İsim veya mesleğe göre ara").foregroundStyle(.white.opacity(0.5))
            )
            .foregroundStyle(.white)
            .font(.system(size: 14))
            .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: Kategori pill'leri

    private var pills: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(ExploreCategory.allCases) { cat in
                    pill(cat)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func pill(_ cat: ExploreCategory) -> some View {
        let active = cat == selectedCategory
        return Button {
            selectedCategory = cat
        } label: {
            Text(cat.title)
                .font(.system(size: 14, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? .white : .white.opacity(0.8))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background {
                    if active {
                        LinearGradient(colors: [AppColor.pink, AppColor.amber],
                                       startPoint: .top, endPoint: .bottom)
                    } else {
                        Color.white.opacity(0.08)
                    }
                }
                .clipShape(Capsule())
                .overlay(
                    Capsule().strokeBorder(.white.opacity(active ? 0 : 0.1), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: PRO banner

    private var proBanner: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(.white.opacity(0.2))
                Image(systemName: "crown.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("PRO'ya geç")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text("Tüm karakterleri gör")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
            Text("PRO'ya Geç")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(hex: 0xFF6F61))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.white, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            LinearGradient(colors: [Color(hex: 0xFFA726), Color(hex: 0xFF6F61)],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .shadow(color: Color(hex: 0xFF6F61).opacity(0.3), radius: 12, y: 6)
    }

    // MARK: Grid

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            Button { showCreate = true } label: { createCard }
                .buttonStyle(.plain)
            ForEach(filtered) { character in
                Button {
                    profileCharacter = character
                } label: {
                    CharacterGridCard(character: character)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// "Kendi karakterinizi yaratın" kartı (şimdilik aksiyonsuz).
    private var createCard: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.15))
                    .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1))
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 64, height: 64)

            Text("Kendi karakterinizi yaratın")
                .font(.system(size: 14, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            Text("AI ile sana özel arkadaş")
                .font(.system(size: 10, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .background(
            LinearGradient(colors: [AppColor.pink.opacity(0.55), AppColor.amber.opacity(0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.white.opacity(0.7), lineWidth: 1.5)
        )
    }
}

/// Tek bir karakter kartı (foto + isim/yaş/ülke/meslek).
private struct CharacterGridCard: View {
    let character: Character

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CachedImage(url: character.photoURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                fallback
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.85)],
                           startPoint: .center, endPoint: .bottom)

            info
                .padding(12)
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topTrailing) { onlineDot.padding(10) }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(character.nameWithAge)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)

            if let country = character.country {
                label("mappin.and.ellipse", country, color: .white.opacity(0.85))
            }
            if let job = character.profession {
                label("briefcase.fill", job, color: AppColor.pinkSoft)
            }
        }
    }

    private func label(_ icon: String, _ text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(color)
    }

    private var onlineDot: some View {
        Circle()
            .fill(Color(hex: 0x34D399))
            .frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(AppColor.bg, lineWidth: 2))
    }

    private var fallback: some View {
        ZStack {
            LinearGradient(colors: [AppColor.bg2, AppColor.card],
                           startPoint: .top, endPoint: .bottom)
            Image(systemName: character.avatarSymbol)
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.3))
        }
    }
}

/// "Tümünü Gör" kategori filtreleri. rawValue, Supabase `category` ile eşleşir.
enum ExploreCategory: String, CaseIterable, Identifiable {
    case all = "Tümü"
    case realistic = "Realistic"
    case anime = "Anime"
    case fantasy = "Fantasy"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Tümü"
        case .realistic: return "Gerçekçi"
        case .anime: return "Anime"
        case .fantasy: return "Fantezi"
        }
    }
}

#Preview {
    ExploreView()
        .environment(CharacterStore())
}
