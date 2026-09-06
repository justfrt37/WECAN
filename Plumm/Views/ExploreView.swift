//
//  ExploreView.swift
//  "Tümünü Gör" sekmesi — kategoriye göre tüm karakter kataloğu.
//  Tasarım: AIGUI .pen "Tümünü Gör" ekranı.
//
//  Karakterler Supabase'ten gelir (CharacterStore). Şimdilik kartlar normal
//  (blursuz) gösterilir; PRO kilidi/blur sonra eklenecek.
//

import SwiftUI
import TipKit

struct ExploreView: View {
    @Environment(CharacterStore.self) private var store

    @State private var selectedCategory: ExploreCategory = .all
    @State private var profileCharacter: Character?
    @State private var showCreate = false

    /// Kategori filtresi uygulanmış liste (engellenenler hariç), kullanıcının
    /// KENDİ karakterleri en üstte.
    private var filtered: [Character] {
        let visible = store.characters.filter { c in
            guard !BlockedCharactersStore.isBlocked(c.id) else { return false }
            return selectedCategory.matches(c.category)
        }
        // Kullanıcının kendi yarattığı karakterler HER ZAMAN en başta
        // (bkz. kullanıcı talebi) — kendi karakterini 40+ katalog karakteri
        // arasında aramak zorunda kalmasın.
        //
        // enumerated() + orijinal indeks karşılaştırması: Swift'in `sorted`ı
        // KARARLI (stable) DEĞİL, yani düz bir `isUserCreated` karşılaştırması
        // katalog karakterlerinin sunucudan gelen sırasını (id.asc) her
        // render'da rastgele bozabilirdi.
        return visible.enumerated()
            .sorted { a, b in
                if a.element.isUserCreated != b.element.isUserCreated { return a.element.isUserCreated }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    private let columns = [GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12)]

    /// Kartın profilini açar — ama önce karakteri O ANKİ listede kimliğinden
    /// yeniden çözer.
    ///
    /// Kapanışın yakaladığı `character` değerine körü körüne güvenilmiyor:
    /// hücre geri dönüşümü yüzünden eski listeye ait bir aksiyon ateşlenirse
    /// (bkz. grid'deki `.id(selectedCategory)` notu) o karakter artık ekranda
    /// GÖRÜNMÜYOR demektir — böyle bir durumda hiçbir şey açmamak, yanlış
    /// karakteri açmaktan iyidir. Normal akışta bu arama her zaman eşleşir ve
    /// davranış değişmez.
    private func open(_ character: Character) {
        guard let fresh = filtered.first(where: { $0.id == character.id }) else { return }
        profileCharacter = fresh
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 16) {
                    pills
                        // Pill satırı grid'in ÜSTÜNDE kalsın ve dokunuşu
                        // kendisi yutsun — kategori değişimi sırasında altta
                        // yeniden kurulan kartlara dokunuş sızmasın.
                        .contentShape(Rectangle())
                        .zIndex(1)
                    grid
                        // Kategori değişince grid'in görünüm KİMLİĞİ de değişir:
                        // LazyVGrid hücreleri geri dönüştürmek yerine sıfırdan
                        // kurar. Aksi halde eski listeye ait bir hücre (ve onun
                        // aksiyon kapanışı) yeni listede yaşamaya devam
                        // edebiliyor — "Kurgusal'a basınca Realistic olan Ivy'nin
                        // kartı açılıyor" raporunun bilinen mekanizması bu
                        // (Ivy, "Tümü" listesinin İLK kartıydı).
                        .id(selectedCategory)
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
        Text("See All")
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
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

    // MARK: Grid

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            Button { showCreate = true } label: { createCard }
                .buttonStyle(.plain)
                .popoverTip(CreateCharacterTip(), arrowEdge: .top)
            ForEach(filtered) { character in
                Button {
                    open(character)
                } label: {
                    CharacterGridCard(character: character)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// "Kendi karakterinizi yaratın" kartı — arka plan olarak "basılı tut"
    /// (ONB5) ekranındaki görsel kullanılır; karta sığması için kırpılarak
    /// doldurulur (bkz. kullanıcı talebi).
    private var createCard: some View {
        ZStack {
            Image(bundleResource: "onb5_bg", ext: "png")
                .resizable()
                .scaledToFill()

            // Yazılar okunur kalsın diye koyu degrade scrim.
            LinearGradient(colors: [.black.opacity(0.30), .black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom)

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

                Text("Create your own character")
                    .font(.system(size: 14, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
            }
            .padding(14)
            .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 18))   // kırparak sığdır
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
            if let job = character.localizedProfession {
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
/// "Fantasy"/"Anime"/"Sci-Fi" hepsi tek "Fictional" kategorisinde birleştirildi
/// (bkz. CreateCharacterView wizard'ı ve chat-image/index.ts'nin styleCue'su).
enum ExploreCategory: String, CaseIterable, Identifiable {
    case all = "All"
    case realistic = "Realistic"
    case fictional = "Fictional"

    var id: String { rawValue }

    /// Bir karakterin `category` alanı bu sekmeye ait mi.
    ///
    /// Düz `==` DEĞİL, üç sebeple: (1) büyük/küçük harf ve baştaki/sondaki
    /// boşluk farkları eşleşmeyi sessizce bozuyordu, (2) eski taksonomiden
    /// kalan "Fantasy"/"Anime"/"Sci-Fi" değerleri artık tek "Fictional"
    /// sekmesinde toplanıyor ama bu değerler hem eski satırlarda hem de
    /// istemcinin disk önbelleğinde (characters_cache.json) hâlâ duruyor
    /// olabilir, (3) kategorisi boş/bilinmeyen bir karakter hiçbir sekmede
    /// kaybolmasın diye "Realistic" sayılıyor (varsayılan kategori odur).
    func matches(_ raw: String?) -> Bool {
        if self == .all { return true }
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "fictional", "fantasy", "anime", "sci-fi", "scifi", "science fiction":
            return self == .fictional
        case "realistic", "":
            return self == .realistic
        default:
            return value == rawValue.lowercased()
        }
    }

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .realistic: return String(localized: "Realistic")
        case .fictional: return String(localized: "Fictional")
        }
    }
}

#Preview {
    ExploreView()
        .environment(CharacterStore())
}
