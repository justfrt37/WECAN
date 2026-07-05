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
            // KÖK NEDEN (bkz. XP/seviye sıfırlanma hatası): bu dal SADECE mesajları
            // geri yüklüyordu, seviyeyi/ilerlemeyi HİÇ diskten okumuyordu — init()'te
            // atanan `max(1, character.relationshipLevel)` yerinde kalıyordu (o alan
            // `characters` tablosunun eski/global sütunu, gerçek kullanıcı seviyesi
            // DEĞİL). ChatListView.load() HER konuşma için chatCache'i önceden
            // doldurduğundan, sohbet listesinden açılan HER sohbet bu dalı tetikliyor
            // — yani level neredeyse HER ZAMAN 1'e sıfırlanıyordu, bir sonraki mesajda
            // da bu yanlış değer updateCache() ile diske kalıcı olarak yazılıyordu.
            if let stored = LocalConversationStore.shared.load(for: character.id) {
                relationshipLevel = stored.level
                levelProgress = stored.levelProgress
            }
            markReadNow()
            refreshCurrentActivity()
            ensureScheduleGenerated()
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
        refreshCurrentActivity()
        ensureScheduleGenerated()
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

        // Zaman farkındalığı için — yeni mesajı eklemeden ÖNCEki son mesajın zamanı.
        let lastMessageAt = messages.last?.createdAt
        messages.append(Message(role: .user, content: text))
        updateCache()
        NotificationScheduler.shared.noteUserSent(character: character)
        inputText = ""
        isSending = true
        errorMessage = nil

        Task {
            await handleWakeUpIfAsleep()
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
                    lastMessageAt: lastMessageAt,
                    currentActivity: currentActivity?.detail
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

                // Eski otomatik-foto sistemi (metinde "foto" geçince statik
                // havuzdan rastgele fotoğraf ekleme) KALDIRILDI — artık foto/ses
                // sadece ilgili düğmeyle gönderilir (bkz. MEDIA_REQUEST_RULE,
                // chat/index.ts). Grok bu turda düğmeyi kullanmasını önerir.
                messages.append(Message(role: .assistant, content: result.reply))

                applyPostReplyEffects(gotPhoto: nil, stored: stored)
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

    /// Fotoğraf isteği bayrağı — `quickReplyRow`'daki kamera düğmesiyle açılır/
    /// kapanır (bkz. ChatView). `isVoiceArmed` ile karşılıklı dışlayıcı: biri
    /// açılınca diğeri kapanır, gönder butonu ikisinden en fazla birine yönelir.
    var isImageArmed: Bool = false

    /// `showsTypingBubble`/pending state ayrımı — fotoğraf üretimi beklenirken
    /// normal "yazıyor" balonuyla AYNI görünmesin diye (bkz. ChatView.messagesList).
    var isSendingImageReply: Bool = false

    /// "Şu an ne yapıyor" — ScheduleLookup ile yerelden hesaplanır, ağ
    /// çağrısı gerektirmez. `nil` = henüz rutin üretilmedi ya da eşleşen
    /// blok yok (chat header bu durumda "Online" göstermeye devam eder).
    var currentActivity: (label: String, detail: String)?

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
            await handleWakeUpIfAsleep()
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
                    lastMessageAt: lastMessageAt,
                    voiceChat: true,
                    currentActivity: currentActivity?.detail
                )

                let elapsed = Date().timeIntervalSince(bubbleStartedAt)
                let wanted = TypingTiming.duration(forReplyLength: result.reply.count)
                let remaining = wanted - elapsed
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }

                // ElevenLabs [tag] işaretleri SADECE seslendirme için — mesajın
                // kalıcı `content`'ine (yerel geçmiş + özetlemeye giden) asla
                // ham haliyle sızmamalı, yoksa Grok sonraki DÜZ metin turlarında
                // kendi geçmişindeki bu işaretleri taklit etmeye başlıyor (bkz.
                // gotchas_and_fixes — "Elif normal mesaja ses etiketiyle cevap
                // veriyor" hatası). Dil tespiti de temiz metinle daha güvenilir.
                let cleanedReply = Self.stripVoiceTags(result.reply)
                let lang = VoiceLanguage.detect(from: cleanedReply)
                let messageID = UUID()
                guard let audioData = await TTSService().synthesizeVoiceMessage(
                    text: result.reply, role: character.personalityRole, vibe: character.vibe, lang: lang,
                    useElevenLabs: true
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
                    id: messageID, role: .assistant, content: cleanedReply,
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

    /// `send()`'in fotoğraf-isteği karşılığı: kullanıcının yazdığı tarif metninden
    /// xAI ile gerçek bir fotoğraf üretir, sonra fotoğraftan SONRA gelen kısa bir
    /// metin tepkisi ister (bkz. chat/index.ts IMAGE_CAPTION_RULE). GEÇMİŞ: model
    /// isteğe bağlı bir [[no_caption]] işareti sunulunca neredeyse HER SEFERİNDE
    /// onu seçiyordu (canlı testte 8/8) — işaret tamamen kaldırıldı, artık her
    /// zaman gerçek bir tepki üretiliyor.
    func sendImageRequest() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, !isLoadingHistory else { return }

        let lastMessageAt = messages.last?.createdAt
        messages.append(Message(role: .user, content: text))
        updateCache()
        NotificationScheduler.shared.noteUserSent(character: character)
        inputText = ""
        isImageArmed = false
        isSending = true
        errorMessage = nil

        Task {
            await handleWakeUpIfAsleep()
            try? await Task.sleep(nanoseconds: UInt64(TypingTiming.randomStartDelay() * 1_000_000_000))
            showsTypingBubble = true
            isSendingImageReply = true
            store?.setTyping(character.id, true)

            do {
                let stored = LocalConversationStore.shared.load(for: character.id)
                let photoURL = try await service.generateChatImage(
                    character: character, prompt: text,
                    localMessages: realMessages(), summary: stored?.summary ?? ""
                )

                showsTypingBubble = false
                isSendingImageReply = false
                messages.append(Message(role: .assistant, content: "", imageURL: photoURL))

                // İsteğe bağlı metin tepkisi — sırayla, fotoğraftan SONRA gelir.
                showsTypingBubble = true
                let bubbleStartedAt = Date()
                let realMsgs = realMessages()
                let result = try await service.sendWithLocalHistory(
                    character: character,
                    localMessages: realMsgs,
                    summary: stored?.summary ?? "",
                    userMessage: text,
                    level: relationshipLevel,
                    lastMessageAt: lastMessageAt,
                    imageReactionChat: true,
                    currentActivity: currentActivity?.detail
                )

                let elapsed = Date().timeIntervalSince(bubbleStartedAt)
                let wanted = TypingTiming.duration(forReplyLength: result.reply.count)
                let remaining = wanted - elapsed
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                showsTypingBubble = false
                store?.setTyping(character.id, false)

                let caption = result.reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if !caption.isEmpty {
                    messages.append(Message(role: .assistant, content: caption))
                }

                applyPostReplyEffects(gotPhoto: photoURL, stored: stored)
            } catch {
                errorMessage = error.localizedDescription
                showsTypingBubble = false
                isSendingImageReply = false
                store?.setTyping(character.id, false)
            }
            isSending = false
        }
    }

    /// Fotoğraf tam ekranda indirilince çağrılır (bkz. ChatView.FullscreenImageView).
    /// Sunucu foto özel/mahrem işaretli VE daha önce hiç tepki verilmemişse bir
    /// cevap döner; öbür türlü `nil` döner ve hiçbir şey olmaz. Bu GERÇEK bir
    /// sohbet turu DEĞİL — XP/seviye etkilenmez, kullanıcı mesajı gösterilmez.
    func reactToPrivateDownload(imageURL: URL) {
        Task {
            let stored = LocalConversationStore.shared.load(for: character.id)
            // `try?` on an `async throws -> String?` flattens to a single-level
            // `String?` in Swift 5 (SE-0230) — nil here means either the call
            // threw OR the server legitimately returned `{ reply: null }`
            // (not private / already reacted). Both cases are a silent no-op.
            guard let reply = try? await service.sendPhotoDownloadReaction(
                character: character,
                localMessages: realMessages(),
                summary: stored?.summary ?? "",
                level: relationshipLevel,
                photoURL: imageURL
            ) else { return }
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            messages.append(Message(role: .assistant, content: trimmed))
            updateCache()
            store?.conversationsVersion += 1
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
        let previousSchedule = stored.schedule
        let characterId = character.id

        Task.detached(priority: .background) { [service = self.service, character = self.character, weak self] in
            guard let result = try? await service.generateLocalSummary(
                character: character,
                messagesToFold: toFold,
                existingSummary: existingSummary,
                previousSchedule: previousSchedule
            ) else { return }
            await MainActor.run {
                LocalConversationStore.shared.updateSummary(
                    for: characterId,
                    summary: result.summary,
                    summarizedCount: windowStart,
                    schedule: result.schedule
                )
                self?.refreshCurrentActivity()
            }
        }
    }

    // MARK: - Günlük rutin

    /// Cihazdaki kayıtlı rutine göre "şu an ne yapıyor" bloğunu yerelden
    /// hesaplar — ağ çağrısı yok, ucuz, her çağrıda güvenle tekrar edilebilir.
    private func refreshCurrentActivity() {
        guard let schedule = LocalConversationStore.shared.load(for: character.id)?.schedule,
              let block = ScheduleLookup.currentBlock(schedule: schedule) else {
            currentActivity = nil
            return
        }
        currentActivity = (label: block.label, detail: block.detail)
    }

    /// Karakter şu an "uyuyor" bloğundaysa, mesaj göndermeden hemen ÖNCE
    /// gerçekliği taklit eden özel bir gecikme akışı çalıştırır: 5sn hiçbir
    /// şey değişmez (hâlâ uyuyor), sonra durum "Az önce uyandı"ya güncellenir,
    /// 5sn daha beklenir, SONRA çağıran normal yazma-balonu akışına devam
    /// eder. `currentActivity` bu süre boyunca mutasyona uğradığı için,
    /// sunucuya gönderilen `currentActivity` bağlamı da otomatik olarak
    /// "az önce uyandı" olur (send*() fonksiyonları bunu bu adımdan SONRA okur).
    private func handleWakeUpIfAsleep() async {
        guard let schedule = LocalConversationStore.shared.load(for: character.id)?.schedule,
              let block = ScheduleLookup.currentBlock(schedule: schedule),
              block.isSleep else { return }

        try? await Task.sleep(nanoseconds: 5_000_000_000)
        currentActivity = (
            label: String(localized: "Just woke up"),
            detail: "just woke up from being asleep, still a little groggy, texting from bed"
        )
        try? await Task.sleep(nanoseconds: 5_000_000_000)
    }

    /// Cihazda hiç rutin yoksa (yeni sohbet) arka planda ilk rutini üretir —
    /// asıl üretim/kaydetme mantığı `ScheduleGenerator`'da (splash'teki toplu
    /// üretimle paylaşılıyor, bkz. CharacterStore.load). Kullanıcının ilk
    /// mesajını GECİKTİRMEZ — tamamlanmadan mesaj gönderilirse o tur sadece
    /// currentActivity bağlamı olmadan devam eder.
    private func ensureScheduleGenerated() {
        Task.detached(priority: .background) { [service = self.service, character = self.character, weak self] in
            await ScheduleGenerator.ensureGenerated(for: character, service: service)
            await MainActor.run { self?.refreshCurrentActivity() }
        }
    }

    /// `ChatView`'in `.task` içinden çağrılır — view kaybolunca SwiftUI
    /// otomatik iptal eder, elle Timer yönetimine gerek yok.
    func startActivityRefreshLoop() async {
        while !Task.isCancelled {
            refreshCurrentActivity()
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }

    // MARK: - Yardımcılar

    private func realMessages() -> [Message] {
        hasSyntheticOpening ? Array(messages.dropFirst()) : messages
    }

    /// ElevenLabs v3 ses etiketlerini ([laughs], [whispers] vb.) metinden
    /// temizler — TTS'e giden ham metinde kalmalı, ama kalıcı `content`'e asla
    /// sızmamalı (bkz. sendVoiceRequest).
    private static func stripVoiceTags(_ text: String) -> String {
        let stripped = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        return stripped
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            ),
            schedule: stored?.schedule
        )
        LocalConversationStore.shared.save(updated, for: character.id)
    }
}
