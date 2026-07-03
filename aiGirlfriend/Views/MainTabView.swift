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
    @State private var selection: MainTab = .discover
    @State private var path = NavigationPath()

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
        }
        .tint(AppColor.pink)
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

/// Henüz içeriği olmayan sekmeler için boş yer tutucu.
struct PlaceholderTab: View {
    let tab: MainTab

    var body: some View {
        ZStack {
            LinearGradient(colors: [AppColor.bg, AppColor.bg2, AppColor.bg],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: tab.icon)
                    .font(.system(size: 44))
                    .foregroundStyle(AppColor.pink.opacity(0.8))
                Text(tab.titleKey)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("Soon")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

#Preview {
    MainTabView()
        .environment(CharacterStore())
        .environment(NavigationCenter())
}
