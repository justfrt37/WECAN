//
//  ChatViewModel.swift
//  Sohbet ekranının durumunu yönetir.
//  Tüm karakterler için: geçmiş cihazda, yerel özetler (her 20 mesajda bir).
//  Sunucu yalnızca XP / level / msg_counter tutar.
//

import Foundation
import Observation

private let localKeepRecent = 20

@MainActor
@Observable
final class ChatViewModel {
    let character: Character

    var messages: [Message] = []
    var inputText: String = ""
    var isSending: Bool = false
    var isLoadingHistory: Bool = true
    var errorMessage: String?

    var relationshipLevel: Int
    var xp: Int = 0
    var leveledUpTo: Int?

    var relationshipStage: String { Relationship.stageName(relationshipLevel, role: character.personalityRole) }

    private let service = ChatService()
    var store: CharacterStore?
    var isVisible = false
    private var hasSyntheticOpening = false

    init(character: Character) {
        self.character = character
        self.relationshipLevel = max(1, character.relationshipLevel)
    }

    private var realAssistantCount: Int {
        let c = messages.filter { $0.role == .assistant }.count
        return max(0, c - (hasSyntheticOpening ? 1 : 0))
    }

    func markReadNow() {
        ReadTracker.setSeen(character.id, realAssistantCount)
    }

    func clearChat() {
        messages = []
        hasSyntheticOpening = false
        store?.chatCache[character.id] = []
        LocalConversationStore.shared.clear(for: character.id)
        ReadTracker.setSeen(character.id, 0)
        Task { await loadHistory() }
    }

    var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSending && !isLoadingHistory
    }

    // MARK: - Geçmişi yükle

    func loadHistory() async {
        // 1. Bellek içi önbellek
        if let cached = store?.chatCache[character.id], !cached.isEmpty {
            messages = cached
            hasSyntheticOpening = false
            isLoadingHistory = false
            markReadNow()
            return
        }

        isLoadingHistory = true
        errorMessage = nil

        // 2. Cihaz yerel depolama
        if let stored = LocalConversationStore.shared.load(for: character.id) {
            xp = stored.xp
            relationshipLevel = stored.level
            messages = stored.messages
            hasSyntheticOpening = false
            store?.chatCache[character.id] = stored.messages
        } else {
            // 3. İlk açılış: sunucudan çek, yerel kaydet (migration)
            await primeFromServer()
        }

        isLoadingHistory = false
        markReadNow()
    }

    /// Sunucudan tek seferlik geçmiş çekme — cihazda yerel JSON yoksa çalışır.
    private func primeFromServer() async {
        do {
            let history = try await service.loadHistory(character: character)
            relationshipLevel = history.level
            xp = history.xp
            if history.messages.isEmpty {
                await attachAIGreeting()
            } else {
                messages = history.messages
                hasSyntheticOpening = false
                store?.chatCache[character.id] = history.messages
                // Sunucudan gelen geçmişi cihaza kaydet
                let stored = LocalConversationStore.Stored(
                    messages: history.messages,
                    xp: xp,
                    level: relationshipLevel,
                    summary: "",
                    summarizedCount: 0
                )
                LocalConversationStore.shared.save(stored, for: character.id)
            }
        } catch {
            errorMessage = error.localizedDescription
            if messages.isEmpty { await attachAIGreeting() }
        }
    }

    // MARK: - AI selamı

    private func attachAIGreeting() async {
        do {
            let greeting = try await service.generateGreeting(character: character)
            messages = [Message(role: .assistant, content: greeting)]
        } catch {
            messages = [Message(role: .assistant, content: fallbackGreeting())]
        }
        hasSyntheticOpening = true
    }

    // MARK: - Anı / davranış kaydet

    /// "Anı Ekle" / "Davranış Ekle" sayfasından çağrılır. `kind` "memory" ya da
    /// "behavior" olmalı. Sunucu reddederse (Grok injection tespiti) ya da ağ
    /// hatası olursa sessizce yutulur — sheet zaten kapanmış olur (ürün kararı).
    func saveNote(kind: String, content: String) {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let characterId = character.id
        Task {
            _ = try? await service.addCharacterNote(characterId: characterId, kind: kind, content: text)
        }
    }

    private func fallbackGreeting() -> String {
        let name = character.name
        switch character.personalityRole {
        case "ex":      return String(localized: "…Sen misin? Bir süredir haber vermemiştin.")
        case "shy":     return String(localized: "O-oh, selam... \(name) burada. Nasılsın? 🙈")
        case "distant": return String(localized: "\(name). Uzun zaman oldu.")
        case "playful": return String(localized: "Heyyy! 🎉 \(name) hazır, sen hazır mısın?")
        case "devoted": return String(localized: "Seni düşünüyordum tam... Selam aşkım 💕")
        case "crazy":   return String(localized: "NIHAYET geldin!! \(name) sabırsızlanıyordu 😤💥")
        default:        return String(localized: "Selam 👋 Ben \(name). Nasılsın?")
        }
    }

    // MARK: - Mesaj gönder

    func send(_ preset: String? = nil) {
        let text = (preset ?? inputText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, !isLoadingHistory else { return }

        let wantsPhoto = photoRequested(text)
        messages.append(Message(role: .user, content: text))
        updateCache()
        inputText = ""
        isSending = true
        errorMessage = nil
        store?.setTyping(character.id, true)

        Task {
            do {
                let stored = LocalConversationStore.shared.load(for: character.id)
                let realMsgs = realMessages()
                let result = try await service.sendWithLocalHistory(
                    character: character,
                    localMessages: realMsgs,
                    summary: stored?.summary ?? "",
                    userMessage: text
                )

                messages.append(Message(role: .assistant, content: result.reply))
                if wantsPhoto, let photo = character.chatPhotos.randomElement() {
                    messages.append(Message(role: .assistant, content: "", imageURL: photo))
                }
                xp = result.xp
                if result.leveledUp { leveledUpTo = result.level }
                relationshipLevel = result.level
                updateCache()
                if isVisible { markReadNow() }

                triggerSummarizationIfNeeded()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSending = false
            store?.setTyping(character.id, false)
        }
    }

    // MARK: - Yerel özetleme

    /// Arka planda çalışır; kullanıcıyı bloklamaz.
    private func triggerSummarizationIfNeeded() {
        guard let stored = LocalConversationStore.shared.load(for: character.id) else { return }
        let real = stored.messages.filter { $0.imageURL == nil }
        let windowStart = max(0, real.count - localKeepRecent)
        guard windowStart > stored.summarizedCount else { return }

        let toFold = Array(real[stored.summarizedCount..<windowStart])
        let existingSummary = stored.summary
        let characterId = character.id

        Task.detached(priority: .background) { [service = self.service, character = self.character] in
            guard let newSummary = try? await service.generateLocalSummary(
                character: character,
                messagesToFold: toFold,
                existingSummary: existingSummary
            ) else { return }
            await MainActor.run {
                LocalConversationStore.shared.updateSummary(
                    for: characterId,
                    summary: newSummary,
                    summarizedCount: windowStart
                )
            }
        }
    }

    // MARK: - Yardımcılar

    private func realMessages() -> [Message] {
        hasSyntheticOpening ? Array(messages.dropFirst()) : messages
    }

    private func photoRequested(_ text: String) -> Bool {
        let t = text.lowercased(with: Locale(identifier: "tr_TR"))
        let keys = ["foto", "fotoğraf", "fotograf", "resim", "selfie", "selfi",
                    "görsel", "gorsel", "pic", "fotonu", "resmini"]
        return keys.contains { t.contains($0) }
    }

    private func updateCache() {
        let real = realMessages()
        guard !real.isEmpty else { return }
        store?.chatCache[character.id] = real
        let stored = LocalConversationStore.shared.load(for: character.id)
        let updated = LocalConversationStore.Stored(
            messages: real,
            xp: xp,
            level: relationshipLevel,
            summary: stored?.summary ?? "",
            summarizedCount: stored?.summarizedCount ?? 0
        )
        LocalConversationStore.shared.save(updated, for: character.id)
    }
}
