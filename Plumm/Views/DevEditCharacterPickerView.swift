//
//  DevEditCharacterPickerView.swift
//  TEMPORARY / DEV-ONLY — "DEV: Edit Existing Character" entry point (bkz.
//  ProfileView). Lists every existing public character (characters table is
//  public-read for everyone; this doesn't filter to catalog-only rows on
//  purpose — a dev may want to touch up a user-created one too) and opens
//  the SAME CreateCharacterView wizard used for normal character creation,
//  in `.edit` mode (bkz. CreateCharacterView.DevWizardMode), prefilled from
//  the tapped row.
//
//  DELETE alongside CreateCharacterView's dev-only steps once curated-character
//  creation/editing is retired.
//

import SwiftUI

struct DevEditCharacterPickerView: View {
    @State private var characters: [DevCharacterFull] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var searchText = ""
    @State private var selected: DevCharacterFull?

    private var filtered: [DevCharacterFull] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return characters }
        return characters.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading characters…")
                } else if let loadError {
                    VStack(spacing: 12) {
                        Text(loadError).foregroundStyle(.red)
                        Button("Retry") { Task { await load() } }
                    }
                } else {
                    List(filtered) { character in
                        Button { selected = character } label: {
                            HStack(spacing: 12) {
                                if let url = character.photoURL {
                                    CachedImage(url: url) { img in
                                        img.resizable().scaledToFill()
                                    } placeholder: { Color.gray.opacity(0.2) }
                                    .frame(width: 44, height: 44)
                                    .clipShape(Circle())
                                }
                                VStack(alignment: .leading) {
                                    Text(character.name).bold()
                                    if let tagline = character.tagline, !tagline.isEmpty {
                                        Text(tagline).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .searchable(text: $searchText, prompt: "Search by name")
                }
            }
            .navigationTitle("DEV: Edit Character")
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .sheet(item: $selected) { character in
                CreateCharacterView(devMode: .edit(character))
            }
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            characters = try await DevCharacterService.fetchAllPublicCharacters()
        } catch {
            loadError = "Couldn't load characters: \(error)"
        }
    }
}

#Preview {
    DevEditCharacterPickerView()
}
