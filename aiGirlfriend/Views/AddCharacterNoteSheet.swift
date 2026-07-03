//
//  AddCharacterNoteSheet.swift
//  "Anı Ekle" / "Davranış Ekle" — ChatView'in gear menüsünden ve Sohbetler
//  listesindeki uzun-basma menüsünden paylaşılan giriş sayfası. Sadece
//  ChatService.addCharacterNote'a ihtiyaç duyar, tam ChatViewModel gerekmez.
//

import SwiftUI

struct AddCharacterNoteSheet: View {
    let character: Character
    /// "Anı Ekle" ya da "Davranış Ekle"
    let titleKey: String

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    private let service = ChatService()

    var body: some View {
        NavigationStack {
            ZStack {
                AppColor.bg.ignoresSafeArea()
                VStack(spacing: 16) {
                    Text(titleKey == "Anı Ekle"
                         ? "\(character.name) bunu hatırlasın:"
                         : "\(character.name) böyle davransın:")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextField("", text: $text,
                              prompt: Text(titleKey == "Anı Ekle" ? "Örn. doğum günüm 5 Mayıs" : "Örn. bana hep 'aşkım' de")
                                .foregroundColor(.white.opacity(0.4)), axis: .vertical)
                        .lineLimit(3...6)
                        .foregroundStyle(.white).tint(AppColor.pink)
                        .padding(12)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    Button {
                        save()
                    } label: {
                        Text("Kaydet").font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 50)
                            .background(LinearGradient(colors: [AppColor.pink, AppColor.amber],
                                                       startPoint: .leading, endPoint: .trailing), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle(titleKey)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    /// Sunucu reddederse (Grok injection tespiti) ya da ağ hatası olursa sessizce
    /// yutulur — sheet zaten kapanmış olur (ürün kararı).
    private func save() {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty {
            let kind = titleKey == "Anı Ekle" ? "memory" : "behavior"
            let characterId = character.id
            Task {
                _ = try? await service.addCharacterNote(characterId: characterId, kind: kind, content: content)
            }
        }
        dismiss()
    }
}
