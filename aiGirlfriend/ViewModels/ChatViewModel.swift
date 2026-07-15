//
//  ChatViewModel.swift
//  Sohbet ekranının durumunu yönetir.
//  Tüm karakterler için: geçmiş cihazda, yerel özetler (her 20 mesajda bir).
//  XP/seviye/terfi hesabı artık SUNUCUDA (bkz. chat/index.ts
//  applyRelationshipGain) — istemci cevaptaki `level`/`levelProgress` değerlerini
//  sadece gösterir/saklar, kurcalayamaz. (Eski istemci mantığı: RelationshipXP.swift.)
//

import Foundation
import Observation
import AVFoundation
import UIKit
import SwiftUI

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
    var tokenStore: TokenStore?

    /// Her başarılı ödemeli çağrıdan sonra çağrılır — TokenBadge'in bir
    /// sonraki `TokenStore.refresh()`'i beklemeden anında güncellenmesi için.
    private func handleTokenBalance(_ balance: Int?) {
        if let balance { tokenStore?.setBalance(balance) }
    }

    /// 402 — bkz. chat/index.ts, chat-image/index.ts, voice-message-tts/index.ts
    /// chargeOrReject. Genel ağ hatası mesajı yerine kullanıcıya net bir sebep
    /// göstermek için ayırt edilir.
    private func isInsufficientTokensError(_ error: Error) -> Bool {
        if case ChatServiceError.badStatus(402, _) = error { return true }
        return false
    }
    var isVisible = false
    private var hasSyntheticOpening = false
    /// PRO gerektiren bir gönderim denendiğinde açılır (bkz. PurchaseService.isPro) —
    /// düğmelere basmak SERBEST (isVoiceArmed/isImageArmed, kamera/mikrofon açma),
    /// sadece gerçek GÖNDERIM anında kontrol edilir.
    var showPaywall = false

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
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Sesli/foto modunda metin ZORUNLU değil — boşsa varsayılan "Sesli mesaj
        // gönder"/"Fotoğraf gönder" metniyle gönderilir (bkz. sendVoiceRequest/sendImageRequest).
        return (hasText || isVoiceArmed || isImageArmed) && !isSending && !isLoadingHistory
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
                    currentActivity: currentActivity?.detail,
                    nearSleepTime: isNearSleepTime()
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
                handleTokenBalance(result.tokenBalance)

                applyPostReplyEffects(gotPhoto: nil, stored: stored,
                                      serverLevel: result.level, serverProgress: result.levelProgress)

                if result.wentToSleep {
                    var updated = LocalConversationStore.shared.load(for: character.id) ?? stored
                    updated?.manualSleepAt = Date()
                    updated?.wokenUpAt = nil
                    if let updated { LocalConversationStore.shared.save(updated, for: character.id) }
                    NotificationScheduler.shared.cancelSleepyGoodnight(for: character.id)
                }
            } catch {
                errorMessage = isInsufficientTokensError(error)
                    ? String(localized: "Not enough tokens. Get more to keep chatting.")
                    : error.localizedDescription
                showsTypingBubble = false
                store?.setTyping(character.id, false)
            }
            isSending = false
        }
    }

    /// Gerçek yatma saatine 1 saatten yakın mı (ya da içinde miyiz) — bkz.
    /// chat/index.ts sleepRule/turnContext. Yerel hesaplanır, ağ çağrısı yok.
    private func isNearSleepTime() -> Bool {
        guard let schedule = LocalConversationStore.shared.load(for: character.id)?.schedule else { return false }
        let now = Date()
        if ScheduleLookup.currentBlock(schedule: schedule, date: now)?.isSleep == true { return true }
        guard let nextStart = ScheduleLookup.nextSleepBlockStart(schedule: schedule, from: now) else { return false }
        return nextStart.timeIntervalSince(now) <= 3600
    }

    /// Kullanıcının KENDİ kaydettiği sesli mesaj — botun sesli CEVAP vermesini
    /// isteme (`sendVoiceRequest`) ile KARIŞTIRILMASIN, bu farklı bir şey:
    /// kullanıcı konuştu, transkript metin olarak Grok'a gider (ücretsiz —
    /// cihaz üstü konuşma tanıma), ses SADECE cihazda oynatılabilir bir
    /// balon olarak kalır. `isVoiceArmed`/`isImageArmed` varsa temizlenir —
    /// kullanıcının kendi girdisi öncelikli, botun ayrı bir medya üretmesini
    /// İSTEMEZ (bkz. plan: "arm-system composition").
    func sendUserVoice(transcript: String, audioURL: URL) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending, !isLoadingHistory else { return }

        let lastMessageAt = messages.last?.createdAt
        let messageID = UUID()
        let duration = (try? AVAudioPlayer(contentsOf: audioURL))?.duration ?? 0
        let savedPath: String? = (try? Data(contentsOf: audioURL)).flatMap {
            VoicePlayer.saveVoiceMessage($0, messageID: messageID)
        }
        messages.append(Message(
            id: messageID, role: .user, content: trimmed,
            voiceLocalPath: savedPath, voiceDuration: duration
        ))
        updateCache()
        NotificationScheduler.shared.noteUserSent(character: character)
        isVoiceArmed = false
        isImageArmed = false
        isSending = true
        errorMessage = nil

        Task {
            await handleWakeUpIfAsleep()
            try? await Task.sleep(nanoseconds: UInt64(TypingTiming.randomStartDelay() * 1_000_000_000))
            showsTypingBubble = true
            store?.setTyping(character.id, true)
            let bubbleStartedAt = Date()

            do {
                let stored = LocalConversationStore.shared.load(for: character.id)
                let result = try await service.sendWithLocalHistory(
                    character: character,
                    localMessages: realMessages(),
                    summary: stored?.summary ?? "",
                    userMessage: trimmed,
                    level: relationshipLevel,
                    lastMessageAt: lastMessageAt,
                    currentActivity: currentActivity?.detail,
                    nearSleepTime: isNearSleepTime()
                )

                let elapsed = Date().timeIntervalSince(bubbleStartedAt)
                let wanted = TypingTiming.duration(forReplyLength: result.reply.count)
                let remaining = wanted - elapsed
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                showsTypingBubble = false
                store?.setTyping(character.id, false)

                messages.append(Message(role: .assistant, content: result.reply))
                handleTokenBalance(result.tokenBalance)
                applyPostReplyEffects(gotPhoto: nil, stored: stored,
                                      serverLevel: result.level, serverProgress: result.levelProgress)

                if result.wentToSleep {
                    var updated = LocalConversationStore.shared.load(for: character.id) ?? stored
                    updated?.manualSleepAt = Date()
                    updated?.wokenUpAt = nil
                    if let updated { LocalConversationStore.shared.save(updated, for: character.id) }
                    NotificationScheduler.shared.cancelSleepyGoodnight(for: character.id)
                }
            } catch {
                errorMessage = isInsufficientTokensError(error)
                    ? String(localized: "Not enough tokens. Get more to keep chatting.")
                    : error.localizedDescription
                showsTypingBubble = false
                store?.setTyping(character.id, false)
            }
            isSending = false
        }
    }

    /// Kullanıcının BOTA gönderdiği kendi fotoğrafı (kamera/kütüphane) —
    /// botun kendi ürettiği fotoğrafla (`sendImageRequest`) KARIŞTIRILMASIN,
    /// ters yön: burada Grok'un vision GİRİŞİNE gerçek bir fotoğraf gidiyor,
    /// karakter buna doğal bir tepki veriyor (bkz. chat/index.ts
    /// USER_PHOTO_REACTION_RULE). Fotoğraf sadece cihazda saklanır, hiçbir
    /// yere yüklenmez (bkz. UserPhotoStore).
    func sendUserPhoto(image: UIImage, caption: String) {
        guard !isSending, !isLoadingHistory else { return }
        guard let base64 = UserPhotoStore.base64JPEG(from: image) else { return }

        let lastMessageAt = messages.last?.createdAt
        let messageID = UUID()
        let savedPath = UserPhotoStore.saveUserPhoto(image, messageID: messageID)
        messages.append(Message(id: messageID, role: .user, content: caption, localImagePath: savedPath))
        updateCache()
        NotificationScheduler.shared.noteUserSent(character: character)
        isVoiceArmed = false
        isImageArmed = false
        isSending = true
        errorMessage = nil

        Task {
            await handleWakeUpIfAsleep()
            try? await Task.sleep(nanoseconds: UInt64(TypingTiming.randomStartDelay() * 1_000_000_000))
            showsTypingBubble = true
            store?.setTyping(character.id, true)
            let bubbleStartedAt = Date()

            do {
                let stored = LocalConversationStore.shared.load(for: character.id)
                let result = try await service.sendUserPhotoMessage(
                    character: character,
                    localMessages: realMessages(),
                    summary: stored?.summary ?? "",
                    userCaption: caption,
                    base64Image: base64,
                    level: relationshipLevel,
                    lastMessageAt: lastMessageAt,
                    currentActivity: currentActivity?.detail,
                    nearSleepTime: isNearSleepTime()
                )

                let elapsed = Date().timeIntervalSince(bubbleStartedAt)
                let wanted = TypingTiming.duration(forReplyLength: result.reply.count)
                let remaining = wanted - elapsed
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                showsTypingBubble = false
                store?.setTyping(character.id, false)

                messages.append(Message(role: .assistant, content: result.reply))
                handleTokenBalance(result.tokenBalance)
                // `gotPhoto: nil` — bu bir GELEN fotoğraf. Seviye/ilerleme sunucudan gelir.
                applyPostReplyEffects(gotPhoto: nil, stored: stored,
                                      serverLevel: result.level, serverProgress: result.levelProgress)

                if result.wentToSleep {
                    var updated = LocalConversationStore.shared.load(for: character.id) ?? stored
                    updated?.manualSleepAt = Date()
                    updated?.wokenUpAt = nil
                    if let updated { LocalConversationStore.shared.save(updated, for: character.id) }
                    NotificationScheduler.shared.cancelSleepyGoodnight(for: character.id)
                }
            } catch {
                errorMessage = isInsufficientTokensError(error)
                    ? String(localized: "Not enough tokens. Get more to keep chatting.")
                    : error.localizedDescription
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

    /// Şu an gerçekten üretim/indirme sürüyor olan pending foto/ses balonları
    /// (bkz. ChatBubble pending dalları — bu id'ler için yükleme çubuğu
    /// gösterilir ve tekrar dokunma engellenir). Kalıcı DEĞİL — sadece bu
    /// oturumda; uygulama yeniden açılırsa yarım kalan bir üretim varsa
    /// balon "dokun, üret" durumuna geri döner (bkz. pendingImagePrompt/
    /// pendingVoiceRequest hâlâ dolu kalır).
    var generatingImageMessageIDs: Set<UUID> = []
    var generatingVoiceMessageIDs: Set<UUID> = []

    /// Sesli mesaj isteğinden HEMEN sonra ~3 sn süren "hazırlanıyor" durumu —
    /// balon önce yanıp sönen mikrofonla (karakter kaydediyormuş hissi)
    /// görünür, sonra kilitli (kalp/token maliyeti) hâle geçer, ancak ondan
    /// SONRA dokunulup web isteği atılabilir (bkz. sendVoiceRequest / PendingVoiceBubble).
    var preparingVoiceMessageIDs: Set<UUID> = []

    /// "Şu an ne yapıyor" — ScheduleLookup ile yerelden hesaplanır, ağ
    /// çağrısı gerektirmez. `nil` = henüz rutin üretilmedi ya da eşleşen
    /// blok yok (chat header bu durumda "Online" göstermeye devam eder).
    var currentActivity: (label: String, detail: String)?

    /// `send()`'in sesli-mesaj karşılığı — ama artık HEMEN üretmez: kullanıcının
    /// metnini gönderir ve karşılığında "ödeme bekleyen" bir sesli mesaj balonu
    /// ekler (bkz. Message.pendingVoiceRequest). Asıl bot cevabı + TTS + token
    /// tahsili SADECE o balona dokununca olur (bkz. generatePendingVoice) —
    /// bu sayede kullanıcı önce token maliyetini görüp sonra karar verir.
    func sendVoiceRequest() {
        guard !isSending, !isLoadingHistory else { return }
        let typed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Kullanıcı bir şey yazmadıysa varsayılan metin: "Sesli mesaj gönder"
        // (buton etiketiyle aynı) — mesaj balonunda bu görünür.
        let text = typed.isEmpty ? String(localized: "Send me a voice") : typed

        let pendingID = UUID()
        messages.append(Message(role: .user, content: text))
        messages.append(Message(id: pendingID, role: .assistant, content: "", pendingVoiceRequest: true))
        updateCache()
        NotificationScheduler.shared.noteUserSent(character: character)
        inputText = ""
        isVoiceArmed = false
        errorMessage = nil

        // ~3 sn "hazırlanıyor" (yanıp sönen mikrofon) — sonra kalp/kilit
        // animasyonlu belirir (bkz. PendingVoiceBubble transition).
        preparingVoiceMessageIDs.insert(pendingID)
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                preparingVoiceMessageIDs.remove(pendingID)
            }
        }
    }

    /// Bir "ödeme bekleyen" sesli mesaj balonuna dokununca — bot cevabını
    /// üretir (ücretsiz, bkz. chat/index.ts voiceChat charge skip), sonra TTS
    /// ile seslendirir (12 token, bkz. voice-message-tts). Ses tam olarak
    /// cihaza kaydedilene KADAR balon "üretiliyor" durumunda kalır.
    func generatePendingVoice(for messageID: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }),
              messages[idx].isPendingVoice,
              !generatingVoiceMessageIDs.contains(messageID),
              // Hâlâ "hazırlanıyor" (yanıp sönen mikrofon) aşamasındaysa henüz
              // dokunulup üretilemez — önce kilitli hâle geçmeli.
              !preparingVoiceMessageIDs.contains(messageID)
        else { return }
        guard let userMessageIdx = messages[..<idx].lastIndex(where: { $0.role == .user }) else { return }
        let text = messages[userMessageIdx].content
        let lastMessageAt = userMessageIdx > 0 ? messages[userMessageIdx - 1].createdAt : nil

        // Bu pending balon YERİNDE güncellenir (kendi "üretiliyor" durumunu
        // gösterir) — en altta AYRI bir "yazıyor/ses" balonu ÇIKMAZ. Aksi hâlde
        // araya başka mesaj (ör. foto) girmişse gösterge yanlış yerde, en altta
        // beliriyordu (bkz. kullanıcı talebi: "en altta ses kayıt çıkıyor").
        generatingVoiceMessageIDs.insert(messageID)
        isSending = true
        errorMessage = nil

        Task {
            await handleWakeUpIfAsleep()
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
                let ttsResult = await TTSService().synthesizeVoiceMessage(
                    text: result.reply, role: character.personalityRole, vibe: character.vibe, lang: lang,
                    useElevenLabs: true, voiceId: character.voiceId
                )
                let audioData: Data
                switch ttsResult {
                case .success(let data, let tokenBalance):
                    audioData = data
                    handleTokenBalance(tokenBalance)
                case .insufficientTokens:
                    generatingVoiceMessageIDs.remove(messageID)
                    errorMessage = String(localized: "Not enough tokens. Get more to keep chatting.")
                    isSending = false
                    return
                case .failure:
                    generatingVoiceMessageIDs.remove(messageID)
                    errorMessage = String(localized: "Voice message failed to generate.")
                    isSending = false
                    return
                }
                guard let savedPath = VoicePlayer.saveVoiceMessage(audioData, messageID: messageID) else {
                    generatingVoiceMessageIDs.remove(messageID)
                    errorMessage = String(localized: "Voice message failed to generate.")
                    isSending = false
                    return
                }
                let duration = (try? AVAudioPlayer(data: audioData))?.duration

                if let finalIdx = messages.firstIndex(where: { $0.id == messageID }) {
                    messages[finalIdx].content = cleanedReply
                    messages[finalIdx].voiceLocalPath = savedPath
                    messages[finalIdx].voiceDuration = duration
                    messages[finalIdx].pendingVoiceRequest = nil
                }
                generatingVoiceMessageIDs.remove(messageID)

                applyPostReplyEffects(gotPhoto: nil, stored: stored)
            } catch {
                generatingVoiceMessageIDs.remove(messageID)
                errorMessage = isInsufficientTokensError(error)
                    ? String(localized: "Not enough tokens. Get more to keep chatting.")
                    : error.localizedDescription
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
    /// Fotoğraf HEMEN üretilmez — kullanıcının tarifi bir "ödeme bekleyen"
    /// balonda (bkz. Message.pendingImagePrompt) saklanır, bulanık gösterilir.
    /// Asıl üretim + 25 token tahsili SADECE o balona dokununca olur (bkz.
    /// generatePendingImage).
    func sendImageRequest() {
        guard !isSending, !isLoadingHistory else { return }
        let typed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Kullanıcı bir şey yazmadıysa varsayılan metin: "Fotoğraf gönder"
        // (buton etiketiyle aynı) — mesaj balonunda bu görünür, tarif olarak da kullanılır.
        let text = typed.isEmpty ? String(localized: "Send me a photo") : typed

        messages.append(Message(role: .user, content: text))
        updateCache()
        NotificationScheduler.shared.noteUserSent(character: character)
        inputText = ""
        isImageArmed = false
        errorMessage = nil

        // Kısa, rastgele bir gecikmeden sonra bulanık balon "gelir" — botun az
        // önce kendi kararıyla bir foto gönderdiği hissi (bkz. kullanıcı talebi:
        // "whoosh" giriş animasyonu, ChatView'daki .transition ile eşleşir).
        Task {
            let delay = Double.random(in: 0.5...1.0)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
                messages.append(Message(role: .assistant, content: "", pendingImagePrompt: text))
            }
            updateCache()
        }
    }

    /// Bir "ödeme bekleyen" foto balonuna dokununca — 25 token tahsil edip
    /// gerçek görseli üretir. Balon, görsel CİHAZA TAM İNENE kadar (sadece
    /// URL dönmesi değil) "üretiliyor" durumunda kalır — `ImageCache.prefetch`
    /// tamamlanmadan `imageURL` set edilmez, yoksa CachedImage 1-2 saniye
    /// boş görünürdü (bkz. kullanıcı talebi).
    func generatePendingImage(for messageID: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }),
              let prompt = messages[idx].pendingImagePrompt,
              messages[idx].imageURL == nil,
              !generatingImageMessageIDs.contains(messageID)
        else { return }

        generatingImageMessageIDs.insert(messageID)
        isSending = true
        errorMessage = nil

        Task {
            await handleWakeUpIfAsleep()
            do {
                let stored = LocalConversationStore.shared.load(for: character.id)
                let imageResult = try await service.generateChatImage(
                    character: character, prompt: prompt,
                    localMessages: realMessages(), summary: stored?.summary ?? "",
                    currentActivity: currentActivity?.detail
                )

                // Gerçekten indirildi garantisi — CachedImage boş kare göstermesin.
                await ImageCache.shared.prefetch([imageResult.url])

                if let finalIdx = messages.firstIndex(where: { $0.id == messageID }) {
                    messages[finalIdx].imageURL = imageResult.url
                    messages[finalIdx].pendingImagePrompt = nil
                }
                generatingImageMessageIDs.remove(messageID)
                handleTokenBalance(imageResult.tokenBalance)
                updateCache()

                // İsteğe bağlı metin tepkisi — sırayla, fotoğraftan SONRA gelir.
                // `imageResult.redirected` true ise (orijinal istek reddedilip
                // yumuşatılmış bir fotoğrafla değiştirildi) normal tepki yerine
                // doğal bir yönlendirme cevabı istenir (bkz. IMAGE_REDIRECT_RULE).
                // Fotoğraftan SONRA gelen metin tepkisi normal "yazıyor" 3-nokta
                // balonuyla gösterilir (foto üretim spinner'ı DEĞİL) — bkz.
                // kullanıcı talebi: "foto altına mesaj gelince typing olmalı".
                showsTypingBubble = true
                store?.setTyping(character.id, true)
                let bubbleStartedAt = Date()
                let realMsgs = realMessages()
                let result = try await service.sendWithLocalHistory(
                    character: character,
                    localMessages: realMsgs,
                    summary: stored?.summary ?? "",
                    userMessage: prompt,
                    level: relationshipLevel,
                    imageReactionChat: true,
                    currentActivity: currentActivity?.detail,
                    imageRedirected: imageResult.redirected
                )

                let elapsed = Date().timeIntervalSince(bubbleStartedAt)
                let wanted = TypingTiming.duration(forReplyLength: result.reply.count)
                let remaining = wanted - elapsed
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                showsTypingBubble = false
                isSendingImageReply = false
                store?.setTyping(character.id, false)

                let caption = result.reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if !caption.isEmpty {
                    messages.append(Message(role: .assistant, content: caption))
                }

                applyPostReplyEffects(gotPhoto: imageResult.url, stored: stored)
            } catch {
                generatingImageMessageIDs.remove(messageID)
                errorMessage = isInsufficientTokensError(error)
                    ? String(localized: "Not enough tokens. Get more to keep chatting.")
                    : error.localizedDescription
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
            // Normal send()'deki AYNI "insan gibi tereddüt" gecikmesi + yazıyor
            // balonu — bu bir arka plan olayı olsa da kullanıcıya ANINDA
            // gelen bir mesaj gibi değil, gerçek bir cevap gibi hissettirsin.
            try? await Task.sleep(nanoseconds: UInt64(TypingTiming.randomStartDelay() * 1_000_000_000))
            showsTypingBubble = true
            store?.setTyping(character.id, true)
            let bubbleStartedAt = Date()

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
            ) else {
                showsTypingBubble = false
                store?.setTyping(character.id, false)
                return
            }
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                showsTypingBubble = false
                store?.setTyping(character.id, false)
                return
            }

            let elapsed = Date().timeIntervalSince(bubbleStartedAt)
            let wanted = TypingTiming.duration(forReplyLength: trimmed.count)
            let remaining = wanted - elapsed
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            showsTypingBubble = false
            store?.setTyping(character.id, false)

            messages.append(Message(role: .assistant, content: trimmed))
            updateCache()
            store?.conversationsVersion += 1
        }
    }

    /// `send()` ve `sendVoiceRequest()` ortak kuyruğu: XP/terfi hesabı,
    /// cache güncelleme, özetleme tetikleme. `gotPhoto` sesli mesaj yolunda
    /// her zaman nil (fotoğraf isteği metin mesajlarına özgü).
    /// Seviye/ilerleme/XP kazanımı SUNUCUDA hesaplanır (bkz. chat/index.ts
    /// applyRelationshipGain) — istemci yalnızca sunucunun cevapta döndürdüğü
    /// `serverLevel`/`serverProgress` değerlerini uygular. Kurcalanamaz. Sunucu
    /// değer döndürmediyse (ör. ses/foto yolu) seviye değiştirilmez.
    private func applyPostReplyEffects(
        gotPhoto: URL?,
        stored: LocalConversationStore.Stored?,
        serverLevel: Int? = nil,
        serverProgress: Double? = nil
    ) {
        let counter = (stored?.msgCounter ?? 0) + 1

        if let serverLevel {
            let previousLevel = relationshipLevel
            if serverLevel > previousLevel {
                levelUpEvent = LevelUpEvent(
                    fromLevel: previousLevel,
                    toLevel: serverLevel,
                    fromStage: Relationship.stageName(previousLevel, role: character.personalityRole),
                    toStage: Relationship.stageName(serverLevel, role: character.personalityRole)
                )
            }
            relationshipLevel = serverLevel
            if let serverProgress { levelProgress = serverProgress }
        }

        updateCache(msgCounter: counter)
        if isVisible { markReadNow() }

        triggerSummarizationIfNeeded()
    }

    // MARK: - Yerel özetleme

    /// Arka planda çalışır; kullanıcıyı bloklamaz.
    private func triggerSummarizationIfNeeded() {
        guard let stored = LocalConversationStore.shared.load(for: character.id) else { return }
        let real = stored.messages.filter { $0.imageURL == nil && $0.localImagePath == nil }
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

    /// Karakter şu an efektif olarak uyuyorsa (bkz. CharacterSleepState) VE
    /// henüz uyandırılmadıysa, mesaj göndermeden hemen ÖNCE gerçekliği taklit
    /// eden özel bir gecikme akışı çalıştırır: 5sn hiçbir şey değişmez (hâlâ
    /// uyuyor), sonra durum "Az önce uyandı"ya güncellenir, 5sn daha beklenir,
    /// SONRA `wokenUpAt` KALICI olarak kaydedilir (bkz. LocalConversationStore
    /// .Stored) — bir daha bu sohbet açık kaldığı sürece bu gecikme TEKRAR
    /// ÇALIŞMAZ ("konuşma devam ettiği sürece uyanık kal"). Zaten uyandırılmışsa
    /// (wokenUpAt != nil) gecikme tamamen atlanır — bu kontrol İLK yapılır,
    /// çünkü CharacterSleepState.isEffectivelyAsleep zaten wokenUpAt != nil
    /// olduğunda `false` döner (doğru davranış onun için) ama bu fonksiyonun
    /// "uyanıkken her mesaj uyku-öncesi zamanlayıcıyı sıfırlasın" gereksinimi
    /// o predicate'e bağlı kalamaz — aksi halde ikinci mesajdan itibaren hiç
    /// tetiklenmez (bkz. Task 7 review, bu tam olarak o hatanın düzeltmesi).
    private func handleWakeUpIfAsleep() async {
        let stored = LocalConversationStore.shared.load(for: character.id)

        if stored?.wokenUpAt != nil {
            // Zaten uyandırılmış — gecikmeyi atla, sadece uyku-öncesi
            // zamanlayıcıyı sıfırla (konuşma devam ettiği sürece uyanık kal).
            NotificationScheduler.shared.scheduleSleepyGoodnight(for: character, from: Date())
            return
        }

        guard CharacterSleepState.isEffectivelyAsleep(stored: stored) else { return }

        try? await Task.sleep(nanoseconds: 5_000_000_000)
        currentActivity = (
            label: String(localized: "Just woke up"),
            detail: "just woke up from being asleep, still a little groggy, texting from bed"
        )
        try? await Task.sleep(nanoseconds: 5_000_000_000)

        guard var updated = LocalConversationStore.shared.load(for: character.id) else { return }
        updated.wokenUpAt = Date()
        updated.manualSleepAt = nil
        LocalConversationStore.shared.save(updated, for: character.id)

        NotificationScheduler.shared.scheduleSleepyGoodnight(for: character, from: Date())
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
            schedule: stored?.schedule,
            wokenUpAt: stored?.wokenUpAt,
            manualSleepAt: stored?.manualSleepAt
        )
        LocalConversationStore.shared.save(updated, for: character.id)
    }
}
