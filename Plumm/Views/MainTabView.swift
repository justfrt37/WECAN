//
//  MainTabView.swift
//  Ana ekran: alttaki 5 sekmeli özel tab bar + içerik.
//  Tasarım: AIGUI .pen "Feed" ekranındaki tab bar.
//

import SwiftUI

/// Keşfet'te "tanışmak ister misin?" onayından gelen sohbet açma isteği —
/// mesaj kutusuna önceden yazılacak açılış metnini de taşır.
struct MeetRequest: Hashable {
    let character: Character
    let prefillText: String
}

enum MainTab: Int, CaseIterable, Identifiable {
    case discover, chat, explore, likes, profile
    var id: Int { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .discover: return "Discover"
        case .chat: return "Chat"
        case .explore: return "See All"
        case .likes: return "Likes"
        case .profile: return "Profile"
        }
    }

    /// Pencil'daki phosphor ikonlarının SF Symbol karşılıkları.
    var icon: String {
        switch self {
        case .discover: return "safari.fill"
        case .chat: return "bubble.left"
        case .explore: return "square.grid.2x2"
        case .likes: return "heart"
        case .profile: return "person"
        }
    }
}

struct MainTabView: View {
    @Environment(CharacterStore.self) private var store
    @Environment(TokenStore.self) private var tokenStore
    @Environment(OnboardingStore.self) private var onboarding
    @State private var selection: MainTab = .discover
    @State private var path = NavigationPath()
    @State private var showTokenStore = false
    @State private var showPaywall = false
    @State private var streakResult: StreakClaimResult?
    @Environment(\.scenePhase) private var scenePhase
    /// `.onAppear` sadece cold launch'ta değil, NavigationStack'te bir chat'ten
    /// GERİ dönüldüğünde de tekrar ateşleniyor — bu yüzden launch-kontrolünü
    /// (paywall) süreç başına TEK sefere kilitliyoruz (bkz. kullanıcı talebi:
    /// "her chat sayfası kapanışında paywall açılıyor").
    @State private var didCheckPaywallOnLaunch = false
    /// Onboarding'i YENİ bitirip chat'e giren kullanıcıda paywall'ı bir sonraki
    /// tetiklemede (onAppear VEYA hemen ardından gelen scenePhase→.active
    /// patlaması, ikisi de app açılışında art arda ateşleniyor) atlar — flag
    /// tüketilince kapanır, sonraki gerçek foreground'larda normal çalışır.
    @State private var skipPaywallDueToOnboarding = false

    /// Onboarding biterken seçilen karakterin (Scarlet/Maya) chat'ini, uygulama
    /// açılır açılmaz DOĞRUDAN açar — paywall YOK (bkz. OnboardingReadyView).
    private func openPendingOnboardingChat() {
        guard let name = onboarding.pendingChatCharacterName else { return }
        if let character = store.characters.first(where: {
            $0.name.localizedCaseInsensitiveContains(name)
        }) {
            // İlk selamı SUNUCUDA oluştur (bkz. injectProactive, "sıfır yerel")
            // — böylece sohbet, reinstall sonrası ve Sohbetler sekmesinde
            // sunucudan görünür. Mesajı ÖNBELLEĞE KOYMUYORUZ: chat ekranı bunu
            // normal "yazıyor" (3 nokta) animasyonuyla göstersin diye
            // pendingFirstHello işaretliyoruz (bkz. ChatViewModel.loadHistory).
            if LocalConversationStore.shared.load(for: character.id) == nil {
                let helloLine = FirstHelloContent.randomLine()
                store.pendingFirstHello = (character.id, helloLine)
                Task {
                    await ChatService().injectProactiveMessage(
                        character: character, kind: "firstHello", text: helloLine, createIfMissing: true
                    )
                }
            }
            path.append(character)
        }
        // Chat göründü → onboarding'i şimdi tamamla (complete önce, sonra pending
        // nil — böylece gate MainTabView'de kalır, OnboardingFlow'a dönmez).
        onboarding.complete()
        onboarding.pendingChatCharacterName = nil
    }

    /// Pro olmayan her kullanıcıya, uygulamaya her girişte (cold launch +
    /// her foreground) paywall'ı gösterir — kokomombo (Apple review modu)
    /// AÇIKSA hiç açılmaz, Pro olsa da olmasa da (bkz. kullanıcı talebi).
    /// Onboarding'i YENİ bitiren kullanıcıda tetiklenmez — paywall'ı zaten
    /// ONB6'da gördü (bkz. openPendingOnboardingChat).
    private func maybeShowPaywall() {
        // `skipPaywallDueToOnboarding` BİLEREK burada tüketilmiyor (onAppear
        // VE hemen ardından gelen scenePhase→.active patlaması aynı açılışta
        // İKİSİ DE bu fonksiyonu çağırabiliyor — tek seferlik tüketim ikinci
        // çağrıda paywall'ı yanlışlıkla açardı). Gerçek bir arka-plan/ön-plan
        // döngüsü olana kadar (bkz. scenePhase == .background) açık kalır.
        guard !skipPaywallDueToOnboarding,
              !ReviewModeService.shared.isEnabled,
              !PurchaseService.shared.isPro else { return }
        showPaywall = true
    }

    /// PRO değilken, token rozetinin (kalp+sayı) yerinde tüm sekmelerde
    /// gösterilen PRO butonu — onboarding paywall'unu (fullscreen) açar.
    private var proButton: some View {
        Button { showPaywall = true } label: {
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
            .shadow(color: .black.opacity(0.30), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        // Tek NavigationStack: ChatView'a push edilince kök (tab bar dahil) yerini
        // alır → chat tam sayfa açılır, tab bar gizlenir (sheet değil).
        NavigationStack(path: $path) {
            ZStack(alignment: .bottom) {
                AppColor.bg.ignoresSafeArea()

                Group {
                    switch selection {
                    case .discover: FeedView()
                    case .chat:     ChatListView()
                    case .explore:  ExploreView()
                    case .likes:    LikesView()
                    case .profile:  ProfileView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                CustomTabBar(selection: $selection)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Character.self) { character in
                ChatView(character: character)
            }
            .navigationDestination(for: MeetRequest.self) { request in
                ChatView(character: request.character, prefillText: request.prefillText)
            }
            .onChange(of: store.pendingMeetRequest) { _, request in
                if let request {
                    path.append(request)
                    store.pendingMeetRequest = nil
                }
            }
            .onChange(of: store.pendingChatCharacter) { _, character in
                if let character {
                    path.append(character)
                    store.pendingChatCharacter = nil
                }
            }
            .onChange(of: store.pendingTab) { _, tab in
                if let tab {
                    selection = tab
                    store.pendingTab = nil
                }
            }
            .onAppear {
                if onboarding.pendingChatCharacterName != nil { skipPaywallDueToOnboarding = true }
                openPendingOnboardingChat()
                if !didCheckPaywallOnLaunch {
                    didCheckPaywallOnLaunch = true
                    maybeShowPaywall()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: maybeShowPaywall()
                // Gerçekten arka plana gitti — bir SONRAKİ .active artık
                // GERÇEK bir yeniden-giriş, onboarding'den gelen tek seferlik
                // muafiyet burada biter.
                case .background: skipPaywallDueToOnboarding = false
                default: break
                }
            }
        }
        .tint(AppColor.pink)
        // NavigationStack'in KENDİSİNE bindirilmiş overlay — kök içeriğe değil,
        // böylece ChatView push edilince (kök yerini alınca) rozet KAYBOLMAZ,
        // her zaman en üstte kalır (bkz. tasarım: "chat içinde de görünmeli").
        .overlay(alignment: .topTrailing) {
            // Yalnızca sekme KÖKLERİNDE (path boş). PRO rozeti/butonu artık
            // SADECE Profile sekmesinde görünür — eskiden HER sekmede (Discover/
            // Chat/Explore/Likes de dahil) nagging gibi görünüyordu (bkz.
            // kullanıcı talebi: "pro logosu sadece profilde görünmeli"). Token
            // rozeti (coin sayısı) PRO olsun olmasın her sekmede kalır — bakiye
            // her yerde faydalı bilgi, PRO'nun aksine bir "satış" değil.
            if path.isEmpty {
                Group {
                    if !PurchaseService.shared.isPro && selection == .profile {
                        proButton
                    } else {
                        TokenBadge(tokenStore: tokenStore) { showTokenStore = true }
                    }
                }
                .padding(.top, 8)
                .padding(.trailing, 16)
            }
        }
        .fullScreenCover(isPresented: $showTokenStore) {
            TokenStoreView(tokenStore: tokenStore)
        }
        .fullScreenCover(isPresented: $showPaywall) { OnboardingPaywallView() }
        .task {
            if let result = await StreakService.claim(), result.granted {
                withAnimation(.easeInOut(duration: 0.3)) { streakResult = result }
            }
        }
        // fullScreenCover alttan kayıyor ve kapanışta karartma sert biçimde
        // yok oluyordu. Ortalı modal için: karartma + kart BİRLİKTE opacity +
        // hafif scale ile yumuşakça açılıp kapanan bir overlay (bkz. kullanıcı
        // talebi: "opacity gidişi smooth olsun").
        .overlay {
            if let result = streakResult {
                StreakPopupView(result: result) {
                    let balance = result.balance
                    withAnimation(.easeInOut(duration: 0.26)) { streakResult = nil }
                    // `setBalance` (not `refresh`) — streak grants trigger the
                    // same "+N tokens" badge animation as any other gain.
                    if let balance { tokenStore.setBalance(balance) }
                }
                .transition(.opacity)
                .zIndex(20)
            }
        }
    }
}

/// Tasarıma uygun alt tab bar.
struct CustomTabBar: View {
    @Binding var selection: MainTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases) { tab in
                let active = tab == selection
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: active ? tab.icon : tab.icon.replacingOccurrences(of: ".fill", with: ""))
                            .font(.system(size: 20, weight: active ? .semibold : .regular))
                            .frame(height: 24)
                        Text(tab.titleKey)
                            .font(.system(size: 10, weight: active ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(active ? AppColor.pink : Color.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(
            AppColor.bg.opacity(0.95)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.white.opacity(0.08)), alignment: .top)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

#Preview {
    MainTabView()
        .environment(CharacterStore())
        .environment(NavigationCenter())
}
