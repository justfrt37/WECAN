//
//  ChatViewModel.swift
//  Sohbet ekranının durumunu yönetir.
//  Tüm karakterler için: geçmiş cihazda, yerel özetler (her 20 mesajda bir).
//  XP/terfi hesabı istemcide (bkz. RelationshipXP) — sunucu yalnızca güncel
//  `relationship_level` değerini saklar/döner.
//

import Foundation
import Observation
import AVFoundation

private let localKeepRecent = 20

@MainActor
@Observable
final class ChatViewModel {
    let character: Character

    var messages: [Message] = []
    var inputText: String = ""
    var isSending: Bool = false
    /// "Yazıyor..." balonu — `isSending` true olduktan bir süre sonra açılır,
    /// cevabın uzunluğuna göre hesaplanan süre kadar açık kalır (bkz. TypingTiming).
    var showsTypingBubble: Bool = false
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
        Task {
            if let store { await ChatMaintenance.clearChat(character: character, store: store) }
            await loadHistory()
        }
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
                await attachFirstHello()
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
                    levelProgress: levelProgress,
                    detectedLanguage: ConversationLanguage.resolve(
                        latestAssistantText: history.messages.last(where: { $0.role == .assistant })?.content,
                        previouslyDetected: nil
                    )
                )
                LocalConversationStore.shared.save(stored, for: character.id)
            }
        } catch {
            errorMessage = error.localizedDescription
            if messages.isEmpty { await attachFirstHello() }
        }
    }

    // MARK: - İlk selam

    /// Botun ilk mesajı artık AI ile üretilmiyor (gecikme + tutarsızlık yaratıyordu) —
    /// sabit 3 varyanttan rastgele biri, normal mesajlaşmadaki gibi kısa bir
    /// "yazıyor" balonu gecikmesinden sonra gelir (bkz. TypingTiming).
    private func attachFirstHello() async {
        isLoadingHistory = false // mesaj listesi görünür olsun ki "yazıyor" balonu gösterilebilsin
        try? await Task.sleep(nanoseconds: UInt64(TypingTiming.randomStartDelay() * 1_000_000_000))
        showsTypingBubble = true
        let line = FirstHelloContent.randomLine()
        try? await Task.sleep(nanoseconds: UInt64(TypingTiming.duration(forReplyLength: line.count) * 1_000_000_000))
        showsTypingBubble = false
        messages = [Message(role: .assistant, content: line)]
        hasSyntheticOpening = true
    }

    // MARK: - Mesaj gönder

    func send(_ preset: String? = nil) {
        let text = (preset ?? inputText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, !isLoadingHistory else { return }

        let wantsPhoto = photoRequested(text)
        // Zaman farkındalığı için — yeni mesajı eklemeden ÖNCEki son mesajın zamanı.
        let lastMessageAt = messages.last?.createdAt
        messages.append(Message(role: .user, content: text))
        updateCache()
        NotificationScheduler.shared.noteUserSent(character: character)
        inputText = ""
        isSending = true
        errorMessage = nil

        Task {
            // Balon anında değil, insan gibi kısa bir tereddütten sonra belirir.
            try? await Task.sleep(nanoseconds: UInt64(TypingTiming.randomStartDelay() * 1_000_000_000))
            showsTypingBubble = true
            store?.setTyping(character.id, true)
            let bubbleStartedAt = Date()

            do {
                let stored = LocalConversationStore.shared.load(for: character.id)
                let realMsgs = realMessages()
                let result = try await service.sendWithLocalHistory(
                    character: character,
                    localMessages: realMsgs,
                    summary: stored?.summary ?? "",
                    userMessage: text,
                    level: relationshipLevel,
                    lastMessageAt: lastMessageAt
                )

                // Cevap hazır olsa bile, balon en az "bunu yazmak ne kadar sürerdi"
                // kadar açık kalsın (2x insan hızı, ama üst sınırla sıkıştırılmış).
                let elapsed = Date().timeIntervalSince(bubbleStartedAt)
                let wanted = TypingTiming.duration(forReplyLength: result.reply.count)
                let remaining = wanted - elapsed
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                showsTypingBubble = false
                store?.setTyping(character.id, false)

                let gotPhoto = wantsPhoto ? character.chatPhotos.randomElement() : nil
                messages.append(Message(role: .assistant, content: result.reply))
                if let gotPhoto {
                    messages.append(Message(role: .assistant, content: "", imageURL: gotPhoto))
                }

                applyPostReplyEffects(gotPhoto: gotPhoto, stored: stored)
            } catch {
                errorMessage = error.localizedDescription
                showsTypingBubble = false
                store?.setTyping(character.id, false)
            }
            isSending = false
        }
    }

    /// Sesli mesaj isteği bayrağı — `quickReplyRow`'daki dalga formu düğmesiyle
    /// açılır/kapanır (bkz. ChatView). Açıkken gönder butonu `sendVoiceRequest()`e yönlenir.
    var isVoiceArmed: Bool = false

    /// `showsTypingBubble` açıkken hangi bekleme balonunun gösterileceğini
    /// ayırt eder — sesli mesaj beklerken normal "yazıyor" 3-nokta balonuyla
    /// AYNI görünmesin diye (bkz. ChatView.messagesList).
    var isSendingVoiceReply: Bool = false

    /// `send()`'in sesli-mesaj karşılığı: aynı metni gönderir, ama cevap
    /// metin balonu yerine sesli mesaj balonu olarak eklenir. `canSend` ile
    /// aynı boş-metin koruması — "boş dürtme" senaryosu yok, chat edge
    /// function'ında değişiklik gerekmiyor.
    func sendVoiceRequest() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, !isLoadingHistory else { return }

        let lastMessageAt = messages.last?.createdAt
        messages.append(Message(role: .user, content: text))
        updateCache()
        NotificationScheduler.shared.noteUserSent(character: character)
        inputText = ""
        isVoiceArmed = false
        isSending = true
        errorMessage = nil

        Task {
            try? await Task.sleep(nanoseconds: UInt64(TypingTiming.randomStartDelay() * 1_000_000_000))
            showsTypingBubble = true
            isSendingVoiceReply = true
            store?.setTyping(character.id, true)
            let bubbleStartedAt = Date()

            do {
                let stored = LocalConversationStore.shared.load(for: character.id)
                let realMsgs = realMessages()
                let result = try await service.sendWithLocalHistory(
                    character: character,
                    localMessages: realMsgs,
                    summary: stored?.summary ?? "",
                    userMessage: text,
                    level: relationshipLevel,
                    lastMessageAt: lastMessageAt
                )

                let elapsed = Date().timeIntervalSince(bubbleStartedAt)
                let wanted = TypingTiming.duration(forReplyLength: result.reply.count)
                let remaining = wanted - elapsed
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }

                let lang = VoiceLanguage.detect(from: result.reply)
                let messageID = UUID()
                guard let audioData = await TTSService().synthesizeVoiceMessage(
                    text: result.reply, role: character.personalityRole, vibe: character.vibe, lang: lang
                ), let savedPath = VoicePlayer.saveVoiceMessage(audioData, messageID: messageID) else {
                    showsTypingBubble = false
                    isSendingVoiceReply = false
                    store?.setTyping(character.id, false)
                    errorMessage = String(localized: "Voice message failed to generate.")
                    isSending = false
                    return
                }
                let duration = (try? AVAudioPlayer(data: audioData))?.duration

                showsTypingBubble = false
                isSendingVoiceReply = false
                store?.setTyping(character.id, false)

                messages.append(Message(
                    id: messageID, role: .assistant, content: result.reply,
                    voiceLocalPath: savedPath, voiceDuration: duration
                ))

                applyPostReplyEffects(gotPhoto: nil, stored: stored)
            } catch {
                errorMessage = error.localizedDescription
                showsTypingBubble = false
                isSendingVoiceReply = false
                store?.setTyping(character.id, false)
            }
            isSending = false
        }
    }

    /// `send()` ve `sendVoiceRequest()` ortak kuyruğu: XP/terfi hesabı,
    /// cache güncelleme, özetleme tetikleme. `gotPhoto` sesli mesaj yolunda
    /// her zaman nil (fotoğraf isteği metin mesajlarına özgü).
    private func applyPostReplyEffects(gotPhoto: URL?, stored: LocalConversationStore.Stored?) {
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
            levelProgress: levelProgress,
            detectedLanguage: ConversationLanguage.resolve(
                latestAssistantText: real.last(where: { $0.role == .assistant })?.content,
                previouslyDetected: stored?.detectedLanguage
            )
        )
        LocalConversationStore.shared.save(updated, for: character.id)
    }
}
