//
//  ChatViewModel.swift
//  Sohbet ekranının durumunu yönetir.
//  Tüm karakterler için: geçmiş cihazda, yerel özetler (her 20 mesajda bir).
//  XP/terfi hesabı istemcide (bkz. RelationshipXP) — sunucu yalnızca güncel
//  `relationship_level` değerini saklar/döner.
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

    struct LevelUpEvent: Equatable {
        let fromLevel: Int
        let toLevel: Int
        let fromStage: String
        let toStage: String
    }

    var relationshipLevel: Int
    /// Güncel seviyenin ne kadarı tamamlandı (0...1) — üst bardaki halka için.
    var levelProgress: Double = 0
    var levelUpEvent: LevelUpEvent?

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
        if let store { ChatMaintenance.clearChat(characterID: character.id, store: store) }
        Task { await loadHistory() }
    }

    var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSending && !isLoadingHistory
    }

    // MARK: - Geçmişi yükle

    func loadHistory() async {
        NotificationScheduler.shared.cancelJealousyTimer(for: character.id)

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
            levelProgress = stored.levelProgress
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
            // Eski mutlak XP sistemi kaldırıldı — ilk göç sonrası mevcut seviyenin
            // ilerlemesi 0'dan başlar (küçük kozmetik sıfırlama, işlevi etkilemez).
            levelProgress = 0
            if history.messages.isEmpty {
                await attachAIGreeting()
            } else {
                messages = history.messages
                hasSyntheticOpening = false
                store?.chatCache[character.id] = history.messages
                // Sunucudan gelen geçmişi cihaza kaydet
                let stored = LocalConversationStore.Stored(
                    messages: history.messages,
                    xp: history.xp,
                    level: relationshipLevel,
                    summary: "",
                    summarizedCount: 0,
                    levelProgress: levelProgress
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

    private func fallbackGreeting() -> String {
        let name = character.name
        switch character.personalityRole {
        case "ex":      return String(localized: "…Is that you? It's been a while since I heard from you.")
        case "shy":     return String(localized: "O-oh, hey... it's \(name). How are you? 🙈")
        case "distant": return String(localized: "\(name). It's been a while.")
        case "playful": return String(localized: "Heyyy! 🎉 \(name) is here, are you ready?")
        case "devoted": return String(localized: "I was just thinking about you... Hey babe 💕")
        case "crazy":   return String(localized: "FINALLY you're here!! \(name) couldn't wait 😤💥")
        default:        return String(localized: "Hey 👋 I'm \(name). How are you?")
        }
    }

    // MARK: - Mesaj gönder

    func send(_ preset: String? = nil) {
        let text = (preset ?? inputText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, !isLoadingHistory else { return }

        let wantsPhoto = photoRequested(text)
        messages.append(Message(role: .user, content: text))
        updateCache()
        NotificationScheduler.shared.noteUserSent(character: character)
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
                    userMessage: text,
                    level: relationshipLevel
                )

                let gotPhoto = wantsPhoto ? character.chatPhotos.randomElement() : nil
                messages.append(Message(role: .assistant, content: result.reply))
                if let gotPhoto {
                    messages.append(Message(role: .assistant, content: "", imageURL: gotPhoto))
                }

                // Terfi hesabı artık istemcide (eskiden chat edge function'daydı,
                // sunucu şimdi sadece en son seviyeyi saklıyor). Seviye arttıkça
                // her tık daha az ilerleme katar (bkz. RelationshipXP.gainPercent).
                let counter = (stored?.msgCounter ?? 0) + 1
                var fraction = 0.0
                if counter % RelationshipXP.messageBatchSize == 0 {
                    fraction += RelationshipXP.messageGainFraction(forLevel: relationshipLevel)
                }
                if gotPhoto != nil {
                    fraction += RelationshipXP.photoGainFraction(forLevel: relationshipLevel)
                }
                let previousLevel = relationshipLevel
                let (newLevel, newProgress) = RelationshipXP.applyGain(
                    fraction, level: relationshipLevel, progress: levelProgress
                )
                if newLevel > previousLevel {
                    levelUpEvent = LevelUpEvent(
                        fromLevel: previousLevel,
                        toLevel: newLevel,
                        fromStage: Relationship.stageName(previousLevel, role: character.personalityRole),
                        toStage: Relationship.stageName(newLevel, role: character.personalityRole)
                    )
                }
                relationshipLevel = newLevel
                levelProgress = newProgress

                updateCache(msgCounter: counter)
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

    private func updateCache(msgCounter: Int? = nil) {
        let real = realMessages()
        guard !real.isEmpty else { return }
        store?.chatCache[character.id] = real
        let stored = LocalConversationStore.shared.load(for: character.id)
        let updated = LocalConversationStore.Stored(
            messages: real,
            xp: stored?.xp ?? 0,
            level: relationshipLevel,
            summary: stored?.summary ?? "",
            summarizedCount: stored?.summarizedCount ?? 0,
            msgCounter: msgCounter ?? stored?.msgCounter ?? 0,
            levelProgress: levelProgress
        )
        LocalConversationStore.shared.save(updated, for: character.id)
    }
}
