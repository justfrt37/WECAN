//
//  CharacterProfileView.swift
//  Karakter profil sayfası — fullscreen sheet.
//  Tasarım: AIGUI .pen "Karakter Profile".
//

import SwiftUI

struct CharacterProfileView: View {
    let character: Character
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var showPaywall = false
    /// Bu kullanıcının bu karakterle olan gerçek seviyesi/ilerlemesi — `character.relationshipLevel`
    /// eski/global bir alan olduğu için (bkz. gotchas), cihazdaki yerel depodan okunur.
    @State private var userLevel: Int = 1
    @State private var userLevelProgress: Double = 0
    /// Chat header'ındakiyle aynı yerel hesap (bkz. ChatViewModel.currentActivity) —
    /// bu view kendi ChatViewModel'ini paylaşmadığı için ayrıca hesaplanır.
    @State private var currentActivity: (label: String, detail: String)?

    private var images: [URL] {
        character.galleryURLs.isEmpty
            ? [character.photoURL].compactMap { $0 }
            : character.galleryURLs
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                AppColor.bg.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        hero
                        about
                            .padding(.horizontal, 24)
                            .padding(.top, 22)
                        interestsSection
                            .padding(.horizontal, 24)
                            .padding(.top, 22)
                        photosSection
                            .padding(.horizontal, 24)
                            .padding(.top, 22)
                            .padding(.bottom, 110) // bottom bar space
                    }
                }
                .ignoresSafeArea(edges: .top)

                closeButton
                    .padding(.trailing, 20)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                // Sticky bottom bar — Gallery + Chat
                VStack(spacing: 0) {
                    Spacer()
                    bottomBar
                }
            }
            .navigationDestination(for: Character.self) { ChatView(character: $0) }
            .toolbar(.hidden, for: .navigationBar)
        }
        .fullScreenCover(isPresented: $showPaywall) { PaywallHostView() }
        .task {
            if let stored = LocalConversationStore.shared.load(for: character.id) {
                userLevel = stored.level
                userLevelProgress = stored.levelProgress
                if let schedule = stored.schedule, let block = ScheduleLookup.currentBlock(schedule: schedule) {
                    currentActivity = (label: block.label, detail: block.detail)
                }
            } else {
                userLevel = max(1, character.relationshipLevel)
                userLevelProgress = 0
            }
        }
    }

    // MARK: Hero (kaydırılabilir resimler + isim + seviye)

    private var hero: some View {
        ZStack(alignment: .bottom) {
            // Kaydırılabilir resimler — hazır galeri fotoğrafları (pre-made)
            // SADECE burada gösteriliyor (bkz. GalleryView, "More Photos" oradan
            // kaldırıldı). İlk foto (ana profil fotosu) her zaman açık — geri
            // kalanı PRO olmayanlar için bulanık/kilitli kalır.
            TabView(selection: $page) {
                ForEach(Array(images.enumerated()), id: \.offset) { idx, url in
                    let locked = idx > 0 && !PurchaseService.shared.isPro
                    ZStack {
                        CachedImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            AppColor.card
                        }
                        .blur(radius: locked ? 22 : 0)

                        if locked {
                            Color.black.opacity(0.25)
                            Button { showPaywall = true } label: {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 34))
                                    .foregroundStyle(.white)
                                    .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 520)
            .clipped()

            // Alt gradient
            LinearGradient(
                colors: [.clear, AppColor.bg.opacity(0.95), AppColor.bg],
                startPoint: .center, endPoint: .bottom
            )
            .frame(height: 280)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)

            VStack(spacing: 14) {
                nameRow
                paginationDots
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
        }
        .frame(height: 520)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
    }

    private var nameRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(character.nameWithAge)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(AppColor.pink)
                }
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: 0x4ECB71)).frame(width: 8, height: 8)
                    Text(currentActivity?.label ?? character.locationText ?? String(localized: "Online"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            Spacer()
            levelCircle
        }
    }

    /// Kalp + LV N, ring seviyenin İÇİNDEKİ ilerlemeyle (levelProgress) orantılı dolar (0 → boş).
    private var levelCircle: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 3)
            Circle()
                .trim(from: 0, to: userLevelProgress)
                .stroke(
                    LinearGradient(colors: [AppColor.pink, AppColor.amber],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: userLevelProgress)
            VStack(spacing: 1) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColor.pink)
                Text("LV \(userLevel)")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 64, height: 64)
    }

    private var paginationDots: some View {
        HStack(spacing: 5) {
            ForEach(images.indices, id: \.self) { i in
                Capsule()
                    .fill(i == page ? Color.white : Color.white.opacity(0.4))
                    .frame(width: i == page ? 18 : 6, height: 6)
            }
        }
    }

    // MARK: Fotoğraflar (ilgi alanları altında, 2 sütun, aşağıya kadar)

    private let photoColumns = [GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)]

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PHOTOS")
                .font(.system(size: 13, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.8))
            LazyVGrid(columns: photoColumns, spacing: 12) {
                ForEach(Array(images.enumerated()), id: \.offset) { idx, url in
                    let locked = idx > 0 && !PurchaseService.shared.isPro
                    ZStack {
                        CachedImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: { AppColor.card }
                        .frame(height: 240)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .blur(radius: locked ? 18 : 0)

                        if locked {
                            Color.black.opacity(0.25)
                            Image(systemName: "lock.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
                        }
                    }
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onTapGesture { if locked { showPaywall = true } }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Hakkımda

    private var about: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ABOUT")
                .font(.system(size: 13, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.8))
            if let profession = character.profession {
                Text(profession)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColor.pinkSoft)
            }
            Text(character.tagline)
                .font(.system(size: 15, weight: .medium))
                .lineSpacing(4)
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: İlgi Alanları

    private var interestsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("INTERESTS")
                .font(.system(size: 13, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.8))
            FlowLayout(spacing: 8) {
                ForEach(Array(character.interests.enumerated()), id: \.offset) { idx, item in
                    interestChip(item, highlighted: idx == 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func interestChip(_ text: String, highlighted: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: highlighted ? .semibold : .medium))
            .foregroundStyle(highlighted ? AppColor.pinkSoft : Color.white.opacity(0.85))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(highlighted ? AppColor.pink.opacity(0.15) : Color.white.opacity(0.08),
                        in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    highlighted ? AppColor.pink.opacity(0.3) : Color.white.opacity(0.12),
                    lineWidth: 1)
            )
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(AppColor.bg.opacity(0.65), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            // Chat — pushes inside this NavigationStack. Galeri butonu kaldırıldı:
            // fotoğraflar artık profil içinde (ilgi alanları altında) inline grid.
            NavigationLink(value: character) {
                Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(
                        LinearGradient(colors: [AppColor.pink, AppColor.amber],
                                       startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 30)
        .padding(.top, 12)
        .background(
            AppColor.bg.opacity(0.95)
                .overlay(
                    Rectangle().frame(height: 1).foregroundStyle(.white.opacity(0.08)),
                    alignment: .top
                )
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

/// Basit sarmalayan (wrap) yerleşim — ilgi alanı chip'leri için.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview {
    CharacterProfileView(character: Character.samples[0])
}
