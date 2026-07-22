//
//  CharacterListView.swift
//  Karakter seçme ekranı (uygulama girişi).
//  Navigasyon NavigationCenter (Bible router) üzerinden yapılır.
//

import SwiftUI

struct CharacterListView: View {
    @Environment(NavigationCenter.self) private var navigationCenter
    private let characters = Character.samples

    var body: some View {
        List(characters) { character in
            Button {
                navigationCenter.navigateToDestination(destinaiton: .chat(character: character))
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: character.avatarSymbol)
                        .font(.system(size: 40))
                        .foregroundStyle(.pink.gradient)
                        .frame(width: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(character.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(character.localizedTagline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("aiGirlfriend")
    }
}

#Preview {
    NavigationStack {
        CharacterListView()
    }
    .environment(NavigationCenter())
}
