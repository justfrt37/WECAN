//
//  NotificationSettingsView.swift
//  Per-bot daily notification cap settings — only lists bots the user is
//  actively talking to (excludes blocked bots entirely). Hourly/interval
//  constants (Ghosted role timers, Jealousy window, Level-Up rule) are fixed
//  and not shown here.
//

import SwiftUI

private enum CapOption: Int, CaseIterable, Identifiable {
    case none = 0, one = 1, two = 2, three = 3, five = 5, unlimited = -1
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none: return String(localized: "None")
        case .unlimited: return "∞"
        default: return "\(rawValue)"
        }
    }

    /// Maps to/from NotificationPreferencesStore's `Int?` cap representation.
    var storedValue: Int? { self == .unlimited ? nil : rawValue }
    static func from(stored: Int?) -> CapOption {
        guard let stored else { return .unlimited }
        return CapOption(rawValue: stored) ?? .unlimited
    }
}

struct NotificationSettingsView: View {
    @Environment(CharacterStore.self) private var store
    @State private var caps: [UUID: CapOption] = [:]

    private var activeBots: [Character] {
        store.characters.filter { character in
            !BlockedCharactersStore.isBlocked(character.id) &&
            LocalConversationStore.shared.load(for: character.id) != nil
        }
    }

    var body: some View {
        List {
            Section {
                Text(String(localized: "Choose how many notifications you want from each bot per day. This doesn't affect other app settings."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section(String(localized: "Bots you're talking to")) {
                ForEach(activeBots) { bot in
                    HStack {
                        Text(bot.name)
                        Spacer()
                        Picker("", selection: capBinding(for: bot.id)) {
                            ForEach(CapOption.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                if activeBots.isEmpty {
                    Text(String(localized: "You're not talking to any bots yet."))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(String(localized: "Notifications"))
        .task { loadCaps() }
    }

    private func loadCaps() {
        for bot in activeBots {
            caps[bot.id] = CapOption.from(stored: NotificationPreferencesStore.dailyCap(for: bot.id))
        }
    }

    private func capBinding(for characterID: UUID) -> Binding<CapOption> {
        Binding(
            get: { caps[characterID] ?? .unlimited },
            set: { newValue in
                caps[characterID] = newValue
                NotificationPreferencesStore.setDailyCap(newValue.storedValue, for: characterID)
            }
        )
    }
}
