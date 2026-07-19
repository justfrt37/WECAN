//
//  LikesView.swift
//  "Beğeniler" sekmesi — seni beğenen karakterler.
//  Tasarım: AIGUI .pen "Lumi - Beğeniler (Premium)".
//  PRO değilse kartlar blur'lu; PRO ise görünür. Şimdilik PRO açık (görünür).
//

import SwiftUI

struct LikesView: View {
    @Environment(CharacterStore.self) private var store

    /// Gerçek PRO durumu (bkz. PurchaseService — RevenueCat bağlanana kadar
    /// varsayılan false). Önceden test için sabit `true` idi; artık gerçek
    /// duruma bağlı, böylece non-pro kilitli/blur görünümü de test edilebilir.
    private var isPro: Bool { PurchaseService.shared.isPro }
    @State private var profileCharacter: Character?
    @State private var showPaywall = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    /// Seni gerçekten beğenen karakterler (bkz. LikedByStore — günde bir kere
    /// rastgele seçilir, bkz. NotificationScheduler.rescheduleLikedYou).
    /// Kullanıcı GERÇEKTEN cevap yazınca listeden düşer — botun ilk açılış
    /// mesajı enjekte edilir edilmez değil, yoksa kullanıcı fark etmeden kaybolur.
    private var likers: [Character] {
        let likedIDs: Set<UUID> = LikedByStore.likedCharacterIDs()
        let candidates: [Character] = store.characters.filter { likedIDs.contains($0.id) }
        let visible: [Character] = candidates.filter { c in
            !hasUserReplied(to: c.id) && !BlockedCharactersStore.isBlocked(c.id)
        }
        let sorted = visible.sorted { a, b in
            let aDate: Date = LikedByStore.likedAt(a.id) ?? .distantPast
            let bDate: Date = LikedByStore.likedAt(b.id) ?? .distantPast
            return aDate > bDate
        }
        return sorted
    }

    private func hasUserReplied(to characterID: UUID) -> Bool {
        LocalConversationStore.shared.load(for: characterID)?.messages.contains { $0.role == .user } ?? false
    }

    private func isNewToday(_ characterID: UUID) -> Bool {
        LikedByStore.likedAt(characterID).map { Calendar.current.isDateInToday($0) } ?? false
    }

    var body: some View {
        // .top alignment — without it the VStack (header + content) sizes to
        // fit and gets vertically CENTERED by the ZStack whenever its content
        // is shorter than the screen (most visibly the empty state, which is
        // small — looked like it was floating mid-screen instead of pinned
        // under the header).
        ZStack(alignment: .top) {
            LinearGradient(colors: [AppColor.bg, AppColor.bg2, AppColor.bg],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                if likers.isEmpty {
                    emptyState
                } else {
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
        }
        .fullScreenCover(item: $profileCharacter) { CharacterProfileView(character: $0) }
        // PRO gerektiren her yerde onboarding paywall'ı (alttan fullscreen) açılır.
        .fullScreenCover(isPresented: $showPaywall) { OnboardingPaywallView() }
    }

    private var header: some View {
        HStack {
            Text("People Who Liked You")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
        }
        // Sağda TokenBadge için yer bırakılıyor (bkz. MainTabView) — burada
        // sadece dekoratif olan (işlevsiz) kalp ikonu kaldırıldı.
        .padding(.leading, 20)
        .padding(.trailing, 96)
        .padding(.vertical, 12)
    }

    private var infoRow: some View {
        // "PRO değil" göstergesi kaldırıldı; sayı canlı/okunur bir kırmızıya
        // alındı (eski AppColor.pink koyu bordo, koyu zeminde soluk kalıyordu).
        Label("\(likers.count) people liked you", systemImage: "heart.fill")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Color(hex: 0xFF5A78))
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(likers) { c in
                Button {
                    if isPro { profileCharacter = c } else { showPaywall = true }
                } label: {
                    LikeCard(character: c, locked: !isPro,
                             badge: isNewToday(c.id) ? "NEW" : nil)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "heart.slash.fill")
                .font(.system(size: 50))
                .foregroundStyle(AppColor.pink.opacity(0.85))
            Text("No new likes yet")
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text("Check back soon — someone new likes you once a day 💕")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, 32)
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
                Text(LocalizedStringKey(badge))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(badge == "PRO" ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xFFB938), Color(hex: 0xFF8E3C)], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(AppColor.pink),
                                in: Capsule())
                    .padding(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Beğeni işareti: sade KIRMIZI kalp (beyaz daire yok), okunması için gölge.
            Image(systemName: "heart.fill")
                .font(.system(size: 24))
                .foregroundStyle(Color(hex: 0xFF2D55))
                .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
                .padding(14)
        }
    }
}

#Preview {
    LikesView().environment(CharacterStore())
}
