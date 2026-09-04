//
//  TokenCostsView.swift
//  "What do tokens buy?" — a plain reference list. Values are display-only
//  (see TokenCosts.swift); the server always decides the real charge.
//  Reached from TokenStoreView (info button) and ProfileView (settings row).
//

import SwiftUI

struct TokenCostsView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable {
        let id = UUID()
        let name: String
        let cost: String
    }

    private let rows: [Row] = [
        .init(name: String(localized: "Send a message"),            cost: "\(TokenCosts.message)"),
        .init(name: String(localized: "Ask for a photo"),           cost: "\(TokenCosts.photo)"),
        .init(name: String(localized: "Send a voice message"),      cost: "\(TokenCosts.voiceMessage)"),
        .init(name: String(localized: "Voice call"),                cost: String(localized: "\(TokenCosts.voiceCallPerMinute) / min")),
        .init(name: String(localized: "Create a character"),        cost: "\(TokenCosts.characterCreation)"),
        .init(name: String(localized: "Boost a relationship level"), cost: String(localized: "50–200")),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(rows) { row in
                        HStack {
                            Text(row.name)
                            Spacer()
                            HStack(spacing: 4) {
                                Text(row.cost).monospacedDigit().fontWeight(.semibold)
                                CoinIcon(size: 13)
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Nicknames are included with Pro+. Earn tokens with your daily streak or top up in the Store.")
                }
            }
            .navigationTitle("Token Costs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview { TokenCostsView() }
