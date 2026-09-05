//
//  ChatViewModel.swift
//  Sohbet ekranının durumunu yönetir.
//  Tüm karakterler için: geçmiş cihazda, yerel özetler (her 20 mesajda bir).
//  XP/seviye/terfi hesabı artık SUNUCUDA (bkz. chat/index.ts
//  applyRelationshipGain) — istemci cevaptaki `level`/`levelProgress` değerlerini
//  sadece gösterir/saklar, kurcalayamaz.
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

    /// Pro+/Max "Rename" (bkz. set-nickname edge function) — cosmetic only,
    /// never reaches a prompt. `displayName` is what the UI (chat header,
    /// chat list row) should actually show instead of `character.name`.
    var characterNickname: String?
    var displayName: String { characterNickname ?? character.name }

    /// Bu chat açık kaldığı sürece gönderilen mesaj sayısı (bkz. `chat_closed`
    /// analytics olayı) — session-scoped, kalıcılaşmaz.
    var messagesSentThisSession = 0

    private let service = ChatService()
    var store: CharacterStore?
    var tokenStore: TokenStore?

    /// Yerel kalıcılaştırmayı (LocalConversationStore load+build+save) MainActor
    /// dışında sıralı biçimde yürütmek için — bkz. updateCache. Seri kuyruk,
    /// ard arda gelen save'lerin (kullanıcı mesajı → asistan mesajı) sırasını
    /// korur; LocalConversationStore zaten NSLock ile thread-safe.
    private static let persistQueue = DispatchQueue(label: "chat.local-persist", qos: .utility)

    /// Her başarılı ödemeli çağrıdan sonra çağrılır — TokenBadge'in bir
    /// sonraki `TokenStore.refresh()`'i beklemeden anında güncellenmesi için.
    private func handleTokenBalance(_ balance: Int?) {
        if let balance { tokenStore?.setBalance(balance) }
    }

    /// Saniye cinsinden bekleme. `Task.sleep`'in nanosaniye dönüşümü onlarca
    /// çağrı yerinde tekrarlanıyordu; süre sıfır/negatifse hiç beklenmez.
    private func pause(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// "Yazıyor" balonunun kalan süresini tamamlar: bu uzunlukta bir cevabı
    /// yazmak ne kadar sürerdi (bkz. TypingTiming) eksi balonun açık kaldığı
    /// süre. Dört ayrı akışta aynı üç satır tekrarlanıyordu.
    private func completeTypingDelay(forReplyLength length: Int, since bubbleStartedAt: Date) async {
        await pause(TypingTiming.duration(forReplyLength: length) - Date().timeIntervalSince(bubbleStartedAt))
    }

    /// 402 — bkz. chat/index.ts, chat-image/index.ts, voice-message-tts/index.ts
    /// chargeOrReject. Genel ağ hatası mesajı yerine kullanıcıya net bir sebep
    /// göstermek için ayırt edilir.
    private func isInsufficientTokensError(_ error: Error) -> Bool {
        if case ChatServiceError.badStatus(402, _) = error { return true }
        return false
    }

    /// chat-image "no_photo_available" (422) — karakterin gönderilebilir foto
    /// havuzu yok/uygun değil. Artık Grok'tan foto ÜRETİLMİYOR (bkz. kullanıcı
    /// talebi), o yüzden havuz boşsa hata gösterilir.
    private func isNoPhotoError(_ error: Error) -> Bool {
        if case ChatServiceError.badStatus(422, let body) = error, body.contains("no_photo_available") { return true }
        return false
    }
    var isVisible = false
    private var hasSyntheticOpening = false
    /// PRO gerektiren bir gönderim denendiğinde açılır (bkz. PurchaseService.isPro) —
    /// düğmelere basmak SERBEST, sadece gerçek GÖNDERIM anında kontrol edilir.
    var showPaywall = false
    /// `showPaywall` hangi tier'ı satmalı — voice gate'leri Pro+ ister, foto/
    /// mesaj gate'leri Pro yeterli. Bunsuz paywall hep Pro'ya açılıyordu; zaten
    /// Pro sahibi biri voice engellenince AYNI (zaten sahip olduğu) paketi
    /// tekrar tekrar görüyordu — "paywall hiç kapanmıyor" gibi görünen şey
    /// aslında yanlış tier'ın gösterilmesiydi (bkz. kullanıcı talebi).
    var paywallTier: SubscriptionTier = .pro
    /// Token yetmediğinde açılan COIN mağazası (PRO kullanıcılar için). PRO
    /// değilse showPaywall (PRO paywall) açılır (bkz. presentInsufficientTokensPaywall).
    var showTokenStore = false

    /// Token yetmediğinde: UYARI YOK — PRO ise coin mağazası, değilse PRO
    /// paywall açılır (bkz. kullanıcı talebi).
    private func presentInsufficientTokensPaywall() {
        if PurchaseService.shared.isPro { showTokenStore = true }
        else { paywallTier = .pro; showPaywall = true }
        // Rozet gerçek (düşük) bakiyeyi göstersin diye tazele.
        Task { await tokenStore?.refresh() }
    }

    /// Mesaj GÖNDERMEDEN ÖNCE kredi kontrolü — bilinen bakiye yetmiyorsa istek
    /// ATILMAZ, paywall açılır ve false döner. (Bakiye bayatsa sunucu 402'si
    /// yine yakalar, bkz. presentInsufficientTokensPaywall.)
    private func hasTokensOrPaywall(cost: Int = 1) -> Bool {
        if (tokenStore?.balance ?? 0) < cost {
            presentInsufficientTokensPaywall()
            return false
        }
        return true
    }

    /// Sunucu cevabını beklemeden rozeti anında düşür — gerçek maliyet cevapla
    /// (handleTokenBalance) ya da hata yolunda `refresh()` ile düzeltilir.
    private func deductBadgeOptimistically(_ cost: Int) {
        if let balance = tokenStore?.balance { tokenStore?.setBalance(balance - cost) }
    }

    /// Gönderim hatası ortak kuyruğu (send / sendUserVoice / sendUserPhoto):
    /// 402 ise uyarı yerine paywall/coin mağazası, değilse mesajı "başarısız"
    /// işaretle + hatayı göster. `refundsBadge` true ise gönderim başında
    /// anında düşülen rozet bakiyesi gerçek değerle düzeltilir (istek sunucuya
    /// ulaşmadıysa ücretlendirme de olmadı); foto yolunda önden düşüş
    /// yapılmadığı için false geçilir.
    private func handleSendFailure(_ error: Error, messageID: UUID, refundsBadge: Bool) {
        if isInsufficientTokensError(error) {
            presentInsufficientTokensPaywall()   // uyarı yok, paywall aç (kendi içinde refresh() var)
        } else {
            errorMessage = error.localizedDescription
            if let idx = messages.firstIndex(where: { $0.id == messageID }) {
                messages[idx].failed = true
            }
            if refundsBadge { Task { await tokenStore?.refresh() } }
        }
        showsTypingBubble = false
        store?.setTyping(character.id, false)
    }

    /// Sunucu "karakter bu turda uyumayı kabul etti" dediyse (bkz.
    /// ChatReply.wentToSleep) yerel uyku durumunu kalıcılaştırır — üç gönderim
    /// yolunda da birebir aynı blok tekrarlanıyordu.
    private func applyWentToSleep(fallback stored: LocalConversationStore.Stored?) {
        var updated = LocalConversationStore.shared.load(for: character.id) ?? stored
        updated?.manualSleepAt = Date()
        updated?.wokenUpAt = nil
        if let updated { LocalConversationStore.shared.save(updated, for: character.id) }
        NotificationScheduler.shared.cancelSleepyGoodnight(for: character.id)
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso8601Plain = ISO8601DateFormatter()

    /// Sunucudan her cevapla dönen kıskançlık durumunu (bkz. ChatReply.jealousyStage
    /// vb.) yerel önbelleğe yansıtır — üç gönderim yolunda da tekrarlanıyordu.
    /// Bir sonraki tam hydrateConversations'ı beklemeden, o anda güncel kalsın
    /// diye (özellikle eskalasyon zamanlayıcısının bir sonraki foreground'da
    /// doğru iptal/kur kararı verebilmesi için).
    private func applyJealousyState(from result: ChatReply, fallback stored: LocalConversationStore.Stored?) {
        guard let stage = result.jealousyStage else { return }
        var updated = LocalConversationStore.shared.load(for: character.id) ?? stored
        updated?.jealousyStage = stage
        updated?.jealousyMoodTurnsLeft = result.jealousyMoodTurnsLeft ?? 0
        if let sentAtString = result.jealousySentAt {
            updated?.jealousySentAt = Self.iso8601WithFractional.date(from: sentAtString)
                ?? Self.iso8601Plain.date(from: sentAtString)
        }
        if let updated { LocalConversationStore.shared.save(updated, for: character.id) }
        if stage != 1 {
            NotificationScheduler.shared.cancelJealousyEscalation(for: character.id)
        }
    }

    /// Sunucudan her cevapla dönen Pro+/Max nickname'leri (bkz.
    /// ChatReply.characterNickname/userNickname) yerel önbelleğe yansıtır —
    /// applyJealousyState ile aynı desende, aynı üç gönderim yolunda çağrılır.
    private func applyNicknames(from result: ChatReply, fallback stored: LocalConversationStore.Stored?) {
        var updated = LocalConversationStore.shared.load(for: character.id) ?? stored
        updated?.characterNickname = result.characterNickname
        updated?.userNickname = result.userNickname
        if let updated { LocalConversationStore.shared.save(updated, for: character.id) }
        characterNickname = result.characterNickname
    }

    /// Called when the "Rename"/"Nickname for You" sheet dismisses — refreshes
    /// `displayName` from the (already optimistically-updated, see
    /// `AddCharacterNoteSheet.save`) local cache without waiting for the next
    /// chat turn's response.
    func refreshNicknameFromCache() {
        characterNickname = LocalConversationStore.shared.load(for: character.id)?.characterNickname
    }

    init(character: Character) {
        self.character = character
        // Seviye/ilerleme İLK KARE'de doğru olsun diye burada okunur: `loadHistory`
        // (ve oradaki sunucu senkronu) sohbet çizildikten SONRA çalıştığı için
        // header önce `character.relationshipLevel` (eski/global sütun, genelde 1)
        // gösterip sonra doğru seviyeye ZIPLIYORDU (bkz. kullanıcı talebi:
        // "seviye geç geliyor"). Kaynak `LocalConversationStore` bellek-içi bir
        // sözlük (disk/ağ YOK) — senkron okumak bedava.
        // Sıra: bellek-içi kayıt → KALICI seviye önbelleği → karakterin global
        // sütunu. Ortadaki adım şart: bellek-içi tablo uygulama her açılışta boş
        // başlıyor, o yüzden ilk açılışta seviye 1 görünüp sonra düzeliyordu
        // (bkz. RelationshipLevelStore).
        if let stored = LocalConversationStore.shared.load(for: character.id) {
            self.relationshipLevel = max(1, stored.level)
            self.levelProgress = stored.levelProgress
        } else if let cached = RelationshipLevelStore.level(for: character.id) {
            self.relationshipLevel = cached.level
            self.levelProgress = cached.progress
        } else {
            self.relationshipLevel = max(1, character.relationshipLevel)
        }
        self.characterNickname = LocalConversationStore.shared.load(for: character.id)?.characterNickname
        EventLogger.shared.log("conversation_opened", ["character_id": character.id])
    }

    private var realAssistantCount: Int {
        let c = messages.filter { $0.role == .assistant }.count
        return max(0, c - (hasSyntheticOpening ? 1 : 0))
    }

    func markReadNow() {
        ReadTracker.setSeen(character.id, realAssistantCount)
    }

    func clearChat(keepLevel: Bool = false, keepMemories: Bool = false, keepBehaviors: Bool = false) {
        // Temizle = sohbet BOŞ kalır. Eskiden hemen ardından loadHistory()
        // çağrılıyordu; o da boş sohbette yeni conversation + "ilk selam"
        // oluşturup mesajı ANINDA geri getiriyordu (bkz. kullanıcı talebi:
        // "temizledim ama geri geliyor"). Artık yalnızca siler, boş bırakır —
        // ilk-selam yalnızca sohbet BİR SONRAKİ açılışında gelir.
        messages = []
        hasSyntheticOpening = false
        Task {
            if let store {
                await ChatMaintenance.clearChat(
                    character: character, store: store,
                    keepLevel: keepLevel, keepMemories: keepMemories, keepBehaviors: keepBehaviors
                )
            }
        }
    }

    /// Başarısız bir mesaj balonuna dokununca — eski (failed) mesajı kaldırır,
    /// AYNI içerikle orijinal gönderim yolunu (send/sendUserVoice/sendUserPhoto)
    /// yeniden çağırır. Hangi yolun kullanılacağı mesajın kendi alanlarından
    /// çıkarılır: voiceLocalPath doluysa sesli mesaj, localImagePath doluysa
    /// kullanıcı fotoğrafı, ikisi de yoksa düz metin.
    func retrySend(messageID: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }),
              messages[idx].failed == true
        else { return }
        let failedMsg = messages[idx]
        messages.remove(at: idx)
        LocalConversationStore.shared.removeMessage(id: messageID, for: character.id)
        store?.chatCache[character.id] = realMessages()

        if let voicePath = failedMsg.voiceLocalPath {
            let audioURL = VoicePlayer.voiceMessagesDirectory.appendingPathComponent(voicePath)
            sendUserVoice(transcript: failedMsg.content, audioURL: audioURL)
        } else if let photoPath = failedMsg.localImagePath,
                  let image = UserPhotoStore.loadUserPhoto(relativePath: photoPath) {
            sendUserPhoto(image: image, caption: failedMsg.content)
        } else {
            send(failedMsg.content)
        }
    }

    var canSend: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText && !isSending && !isLoadingHistory
    }

    // MARK: - Geçmişi yükle

    func loadHistory() async {
        NotificationScheduler.shared.cancelJealousyTimer(for: character.id)

        // 0. Onboarding ilk-selamı: mesaj sunucuya zaten kalıcı yazıldı (bkz.
        //    MainTabView.openPendingOnboardingChat) — burada ANINDA göstermek
        //    yerine normal "yazıyor" (3 nokta) animasyonuyla getir. Sadece ilk
        //    açılışta; sinyal tüketilir, sonraki açılışlar önbellekten/sunucudan gelir.
        if let pending = store?.pendingFirstHello, pending.characterID == character.id {
            store?.pendingFirstHello = nil
            await attachFirstHello(line: pending.line, synthetic: false)
            markReadNow()
            refreshCurrentActivity()
            ensureScheduleGenerated()
            return
        }

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
            // Seviye/ilerlemeyi SUNUCUDAN kesinle (arka planda, mesajı bloklamadan):
            // bellek-içi store hidrasyonu gecikmiş olabileceğinden açılışta seviye
            // init değerinde (karakterin global seviyesi) takılı kalıp "ilk mesajdan
            // sonra düzeliyor"du (bkz. kullanıcı talebi). Artık açılışta düzelir.
            Task { await syncLevelFromServer() }
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
            levelProgress = history.levelProgress ?? 0
            store?.setLevel(character.id, level: relationshipLevel, progress: levelProgress)
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

    /// Sohbet açılışında seviye/ilerlemeyi SUNUCUDAN (history modu) kesinler —
    /// önbellekten anında açılan sohbette, bellek-içi store hidrasyonu gecikse
    /// bile seviye doğru görünsün (ilk mesajı beklemeden). Mesajları DEĞİŞTİRMEZ.
    private func syncLevelFromServer() async {
        guard let history = try? await service.loadHistory(character: character) else { return }
        relationshipLevel = history.level
        if let lp = history.levelProgress { levelProgress = lp }
        store?.setLevel(character.id, level: relationshipLevel, progress: levelProgress)
    }

    // MARK: - İlk selam

    /// Botun ilk mesajı artık AI ile üretilmiyor (gecikme + tutarsızlık yaratıyordu) —
    /// sabit 3 varyanttan rastgele biri, normal mesajlaşmadaki gibi kısa bir
    /// "yazıyor" balonu gecikmesinden sonra gelir (bkz. TypingTiming).
    /// `line` verilirse o satır kullanılır (onboarding ilk-selamı — sunucuya
    /// zaten kalıcı yazılmış), yoksa rastgele bir varyant seçilir (salt yerel).
    /// `synthetic`: true ise mesaj sunucuda YOK (salt görsel açılış selamı,
    /// realMessages/okundu sayımından hariç); false ise sunucuda kalıcıdır
    /// (gerçek bir mesaj gibi sayılır ve önbelleğe alınır).
    private func attachFirstHello(line: String? = nil, synthetic: Bool = true) async {
        isLoadingHistory = false // mesaj listesi görünür olsun ki "yazıyor" balonu gösterilebilsin
        await pause(TypingTiming.randomStartDelay())
        showsTypingBubble = true
        let helloLine = line ?? FirstHelloContent.randomLine()
        await pause(TypingTiming.duration(forReplyLength: helloLine.count))
        showsTypingBubble = false
        messages = [Message(role: .assistant, content: helloLine)]
        hasSyntheticOpening = synthetic
        if !synthetic { store?.chatCache[character.id] = messages }
    }

    // MARK: - Mesaj gönder

    func send(_ preset: String? = nil) {
        let text = (preset ?? inputText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, !isLoadingHistory else { return }
        let cost = 1
        // Kredi yetmiyorsa istek ATMA — paywall aç (PRO→coin, değilse→PRO).
        guard hasTokensOrPaywall(cost: cost) else { return }

        // Zaman farkındalığı için — yeni mesajı eklemeden ÖNCEki son mesajın zamanı.
        let lastMessageAt = messages.last?.createdAt
        let userMsg = Message(role: .user, content: text)
        messages.append(userMsg)
        LocalConversationStore.shared.appendMessage(userMsg, for: character.id, defaultLevel: relationshipLevel, defaultLevelProgress: levelProgress)
        store?.chatCache[character.id] = realMessages()
        NotificationScheduler.shared.noteUserSent(character: character)
        messagesSentThisSession += 1
        EventLogger.shared.log("message_sent", ["character_id": character.id, "kind": "text"])
        inputText = ""
        isSending = true
        errorMessage = nil
        deductBadgeOptimistically(cost)

        Task {
            await handleWakeUpIfAsleep()
            // Balon anında değil, insan gibi kısa bir tereddütten sonra belirir.
            await pause(TypingTiming.randomStartDelay())
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

                // Grok düz metinde foto/ses isteğini anlarsa MEDIA_REQUEST_RULE
                // gereği [[SEND_PHOTO: ...]]/[[SEND_VOICE]] işaretiyle işaretler,
                // sunucu bunu ayrıştırıp `autoMedia` olarak döner (metinden
                // temizlenmiş hâlde, bkz. chat/index.ts parseMediaIntent). Burada
                // AYNI düğmeye-basılmış-gibi kilitli balon akışı tetiklenir —
                // üretim/blur/token maliyeti (bkz. generatePendingImage/Voice)
                // BİREBİR aynı, düğmelerin kendisi de değişmeden çalışmaya devam
                // eder (bkz. kullanıcı talebi 2026-08-26).
                await deliverSegments(result, bubbleStartedAt: bubbleStartedAt)
                handleTokenBalance(result.tokenBalance)
                triggerAutoMediaIfNeeded(result.autoMedia)

                applyPostReplyEffects(gotPhoto: nil, stored: stored,
                                      serverLevel: result.level, serverProgress: result.levelProgress)

                if result.wentToSleep { applyWentToSleep(fallback: stored) }
                applyJealousyState(from: result, fallback: stored)
                applyNicknames(from: result, fallback: stored)
            } catch {
                handleSendFailure(error, messageID: userMsg.id, refundsBadge: true)
            }
            isSending = false
        }
    }

    /// İstemci taraflı uzunluk sınırı — bkz. maybeSplitForLength. Sunucunun
    /// [PAUSE:n]/DRAMATIC_PACING_RULE mantığına EK, onu DEĞİŞTİRMEZ.
    /// KARAKTER sayısına göre (KELİME değil) — 7 dilde (en/tr/de/fr/es/it/pt)
    /// canlı veri karşılaştırması (2026-08-27): kelime başına karakter oranı
    /// dillerde 5.5-6.5 arasında sıkı bir bantta (Türkçe 6.5, İngilizce 6.0,
    /// İtalyanca 5.6) ama ORTALAMA KELİME SAYISI dile göre çok değişiyor
    /// (İngilizce cevaplar ortalama 26.9 kelime, Türkçe 16.7 — İngilizce'ye
    /// aynı kelime eşiğini uygulamak dile göre çok farklı davranırdı).
    /// Karakter eşiği tüm diller için TEK sayı seti ile adil çalışır. Eşikler
    /// eski kelime sınırlarının (10/30) Türkçe ortalama oranına (~6.5 kar/
    /// kelime) göre karakter karşılığı.
    private static let hardCharCap = 195
    private static let softCharThreshold = 65
    private static let softSplitChance = 0.5

    /// İkinci parçanın "yazıyor..." süresi — kalan metnin uzunluğuna göre
    /// 2-4 saniye arasına sıkıştırılır (TypingTiming ile aynı karakter/saniye
    /// varsayımı, farklı bant — bu bir duraklama, tam yazma süresi değil).
    private static func splitDelay(forRemainingLength length: Int) -> TimeInterval {
        let raw = Double(length) / 30.0
        return min(max(raw, 2.0), 4.0)
    }

    /// Kaba cümle bölücü — "." "!" "?" "…" görülünce cümleyi kapatır. Kısaltma/
    /// ondalık sayı gibi durumları ayırt etmez ama gündelik mesajlaşma metni
    /// için yeterli (yanlış bölünme en kötü ihtimalle kısa bir ekstra balon).
    private func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".!?…".contains(ch) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { sentences.append(trimmed) }
        return sentences
    }

    /// Tek bir balonu, karakter sayısına göre cümle sonunda ikiye böler.
    /// hardCharCap üzerinde HER ZAMAN, softCharThreshold üzerinde %50
    /// ihtimalle böler — cümle sınırı yoksa (tek cümle) bölünmez (bkz.
    /// kullanıcı talebi: dil-bağımsız eşik için kelime yerine karakter).
    private func maybeSplitForLength(_ segment: ReplySegment) -> [ReplySegment] {
        let length = segment.text.count
        let shouldSplit: Bool
        if length > Self.hardCharCap {
            shouldSplit = true
        } else if length > Self.softCharThreshold {
            shouldSplit = Double.random(in: 0..<1) < Self.softSplitChance
        } else {
            shouldSplit = false
        }
        guard shouldSplit else { return [segment] }

        let sentences = splitSentences(segment.text)
        guard sentences.count >= 2 else { return [segment] }

        let half = max(1, length / 2)
        var firstPart: [String] = []
        var charsSoFar = 0
        for s in sentences {
            firstPart.append(s)
            charsSoFar += s.count
            if charsSoFar >= half { break }
        }
        let restSentences = Array(sentences.dropFirst(firstPart.count))
        guard !restSentences.isEmpty else { return [segment] }

        let restText = restSentences.joined(separator: " ")
        return [
            ReplySegment(text: firstPart.joined(separator: " "), delaySeconds: segment.delaySeconds),
            ReplySegment(text: restText, delaySeconds: Self.splitDelay(forRemainingLength: restText.count)),
        ]
    }

    /// `send()`/`sendUserVoice()`/`sendUserPhoto()` ortak balon teslim mantığı —
    /// üçünde de aynı 20 satırlık "kalan süre kadar bekle, balonu kapat, mesajı
    /// ekle" bloğu tekrarlanıyordu, artık tek yerde. `result.replySegments`
    /// doluysa (bkz. DRAMATIC_PACING_RULE) her parçayı ayrı bir balon olarak,
    /// aralarında `delaySeconds` kadar "yazıyor..." göstererek art arda ekler;
    /// boşsa/nil ise eski tek-balon davranışına düşer (voice/image-reaction
    /// turları ve her türlü eski sunucu cevabı için sıfır riskli geri dönüş).
    private func deliverSegments(_ result: ChatReply, bubbleStartedAt: Date) async {
        let serverSegments: [ReplySegment]
        if let paced = result.replySegments, !paced.isEmpty {
            serverSegments = paced
        } else {
            serverSegments = [ReplySegment(text: result.reply, delaySeconds: 0)]
        }
        // Sunucunun kendi [PAUSE:n] mantığı AYNEN korunur — bu sadece EK bir
        // istemci-taraflı geçiş: her balonu, uzunluğuna göre ayrıca bölebilir
        // (bkz. maybeSplitForLength). Sunucu zaten bölmüşse her parça yine bu
        // filtreden geçer, tek balon döndüyse de aynı mantık uygulanır.
        let segments: [ReplySegment] = serverSegments.flatMap { maybeSplitForLength($0) }

        for (index, segment) in segments.enumerated() {
            if index == 0 {
                // İlk parça: mevcut davranış — balon zaten çağrı ÖNCESİNDE
                // açılmıştı, sadece "bunu yazmak ne kadar sürerdi" kadar tamamla.
                await completeTypingDelay(forReplyLength: segment.text.count, since: bubbleStartedAt)
            } else {
                // Sonraki parçalar: balonu YENİDEN aç, dramatik duraklamayı
                // "yazıyor..." animasyonuyla göster.
                showsTypingBubble = true
                store?.setTyping(character.id, true)
                await pause(segment.delaySeconds)
            }
            showsTypingBubble = false
            store?.setTyping(character.id, false)
            let replyMsg = Message(role: .assistant, content: segment.text)
            messages.append(replyMsg)
            LocalConversationStore.shared.appendMessage(replyMsg, for: character.id, defaultLevel: relationshipLevel, defaultLevelProgress: levelProgress)
        }
        LocalConversationStore.shared.refreshDetectedLanguage(for: character.id)
        store?.chatCache[character.id] = realMessages()
    }

    /// Gerçek yatma saatine 1 saatten yakın mı (ya da içinde miyiz) — bkz.
    /// chat/index.ts sleepRule/turnContext. Yerel hesaplanır, ağ çağrısı yok.
    ///
    /// UYKU ÖZELLİĞİ YENİDEN AÇILDI (kullanıcı talebi 2026-08-31 — 2026-08-26'da
    /// kapatılmıştı). Bu SADECE konuşma-içi uyku anlaşması özelliğini
    /// (sleepRule/classifySleepAgreement) tetikler — programın kendisi artık
    /// hiçbir şeyi ENGELLEMEZ (bkz. CharacterSleepState), sadece burada "yatma
    /// vaktine yakın mı" bilgisi için okunuyor.
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
    /// balon olarak kalır.
    func sendUserVoice(transcript: String, audioURL: URL) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending, !isLoadingHistory else { return }
        let cost = 1
        // Kredi yetmiyorsa istek ATMA — paywall aç.
        guard hasTokensOrPaywall(cost: cost) else { return }

        let lastMessageAt = messages.last?.createdAt
        let messageID = UUID()
        let duration = (try? AVAudioPlayer(contentsOf: audioURL))?.duration ?? 0
        let savedPath: String? = (try? Data(contentsOf: audioURL)).flatMap {
            VoicePlayer.saveVoiceMessage($0, messageID: messageID)
        }
        let userMsg = Message(
            id: messageID, role: .user, content: trimmed,
            voiceLocalPath: savedPath, voiceDuration: duration
        )
        messages.append(userMsg)
        LocalConversationStore.shared.appendMessage(userMsg, for: character.id, defaultLevel: relationshipLevel, defaultLevelProgress: levelProgress)
        store?.chatCache[character.id] = realMessages()
        NotificationScheduler.shared.noteUserSent(character: character)
        messagesSentThisSession += 1
        EventLogger.shared.log("message_sent", ["character_id": character.id, "kind": "voice"])
        isSending = true
        errorMessage = nil
        deductBadgeOptimistically(cost)

        Task {
            await handleWakeUpIfAsleep()
            await pause(TypingTiming.randomStartDelay())
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

                await deliverSegments(result, bubbleStartedAt: bubbleStartedAt)
                handleTokenBalance(result.tokenBalance)
                applyPostReplyEffects(gotPhoto: nil, stored: stored,
                                      serverLevel: result.level, serverProgress: result.levelProgress)

                if result.wentToSleep { applyWentToSleep(fallback: stored) }
                applyJealousyState(from: result, fallback: stored)
                applyNicknames(from: result, fallback: stored)
            } catch {
                handleSendFailure(error, messageID: userMsg.id, refundsBadge: true)
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
        let userMsg = Message(id: messageID, role: .user, content: caption, localImagePath: savedPath)
        messages.append(userMsg)
        LocalConversationStore.shared.appendMessage(userMsg, for: character.id, defaultLevel: relationshipLevel, defaultLevelProgress: levelProgress)
        store?.chatCache[character.id] = realMessages()
        NotificationScheduler.shared.noteUserSent(character: character)
        isSending = true
        errorMessage = nil

        Task {
            await handleWakeUpIfAsleep()
            await pause(TypingTiming.randomStartDelay())
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

                await deliverSegments(result, bubbleStartedAt: bubbleStartedAt)
                handleTokenBalance(result.tokenBalance)
                // `gotPhoto: nil` — bu bir GELEN fotoğraf. Seviye/ilerleme sunucudan gelir.
                applyPostReplyEffects(gotPhoto: nil, stored: stored,
                                      serverLevel: result.level, serverProgress: result.levelProgress)

                if result.wentToSleep { applyWentToSleep(fallback: stored) }
                applyJealousyState(from: result, fallback: stored)
                applyNicknames(from: result, fallback: stored)
            } catch {
                // Foto yolunda rozet önden düşürülmüyor → düzeltme de gerekmez.
                handleSendFailure(error, messageID: userMsg.id, refundsBadge: false)
            }
            isSending = false
        }
    }

    /// `showsTypingBubble` açıkken hangi bekleme balonunun gösterileceğini
    /// ayırt eder — sesli mesaj beklerken normal "yazıyor" 3-nokta balonuyla
    /// AYNI görünmesin diye (bkz. ChatView.messagesList).
    var isSendingVoiceReply: Bool = false

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
    /// "Send me a voice" düğmesi — tek dokunuş. Metinli istek YOK (kullanıcı
    /// talebi): kullanıcı mesajı eklenmez, sadece kilitli sesli mesaj balonu
    /// düşer; üretim + tahsil o balona dokununca (bkz. generatePendingVoice).
    func sendVoiceRequest() {
        guard !isSending, !isLoadingHistory else { return }
        // Ses, Pro+ ve Pro Max hakkı (Pro'da YOK, bkz. entitlements.ts) — hakkı
        // olmayana (kredi yetse bile) paywall aç, üretme.
        guard PurchaseService.shared.canUseVoice else { paywallTier = .proPlus; showPaywall = true; return }
        NotificationScheduler.shared.noteUserSent(character: character)
        errorMessage = nil
        appendPendingVoiceBubble(requestText: String(localized: "Send me a voice"))
    }

    /// Kilitli sesli mesaj balonunu ekler — hem düğme akışı (`sendVoiceRequest`,
    /// kullanıcı mesajını KENDİSİ ekler, buraya sadece istek metnini geçirir)
    /// hem de Grok'un düz metinde ses isteğini anlayıp [[SEND_VOICE]] işareti
    /// döndürdüğü otomatik akış (bkz. `send()`, MEDIA_REQUEST_RULE) AYNI bu
    /// fonksiyonu çağırır — üretim/kilit/maliyet (12 token, bkz.
    /// generatePendingVoice) TEK yerde, iki yol arasında fark yok.
    private func appendPendingVoiceBubble(requestText: String) {
        let pendingID = UUID()
        let pendingMsg = Message(id: pendingID, role: .assistant, content: "",
                                 pendingVoiceRequest: true, pendingVoiceRequestText: requestText)
        messages.append(pendingMsg)
        LocalConversationStore.shared.appendMessage(pendingMsg, for: character.id, defaultLevel: relationshipLevel, defaultLevelProgress: levelProgress)
        store?.chatCache[character.id] = realMessages()

        // "Kilitli/açılmamış" sesi SUNUCUDA sakla (foto isteğindeki gibi) — üretmeden
        // çıkıp girse bile kilitli ses balonu olarak geri gelir (kind=voice_pending).
        Task { await service.saveVoiceMessage(character: character, requestText: requestText, url: nil) }

        // ~3 sn "hazırlanıyor" (yanıp sönen mikrofon) — sonra kalp/kilit
        // animasyonlu belirir (bkz. PendingVoiceBubble transition).
        preparingVoiceMessageIDs.insert(pendingID)
        Task {
            await pause(3)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                _ = preparingVoiceMessageIDs.remove(pendingID)
            }
        }
    }

    /// Bir "ödeme bekleyen" sesli mesaj balonuna dokununca — bot cevabını
    /// üretir (ücretsiz, bkz. chat/index.ts voiceChat charge skip), sonra TTS
    /// ile seslendirir (12 token, bkz. voice-message-tts). Ses tam olarak
    /// cihaza kaydedilene KADAR balon "üretiliyor" durumunda kalır.
    func generatePendingVoice(for messageID: UUID) {
        // Ses, Pro+ ve Pro Max hakkı (Pro'da YOK) — hakkı yoksa üretme, paywall aç.
        guard PurchaseService.shared.canUseVoice else { paywallTier = .proPlus; showPaywall = true; return }
        guard let idx = messages.firstIndex(where: { $0.id == messageID }),
              messages[idx].isPendingVoice,
              !generatingVoiceMessageIDs.contains(messageID),
              // Hâlâ "hazırlanıyor" (yanıp sönen mikrofon) aşamasındaysa henüz
              // dokunulup üretilemez — önce kilitli hâle geçmeli.
              !preparingVoiceMessageIDs.contains(messageID)
        else { return }
        guard let userMessageIdx = messages[..<idx].lastIndex(where: { $0.role == .user }) else { return }
        // Token yetmiyorsa HİÇ loading gösterme — doğrudan paywall/coin mağazası.
        guard hasTokensOrPaywall(cost: 12) else { return }
        deductBadgeOptimistically(12)
        let text = messages[userMessageIdx].content
        // Sunucudaki kilitli (voice_pending) satırı gerçek sese çevirmek için
        // AYNI requestText gerekir — bu, pending balonu oluşturulurken sunucuya
        // yazılan metin (bkz. appendPendingVoiceBubble / Message.fromServer).
        // Otomatik [[SEND_VOICE]] akışında bu "Send me a voice"dır, `text` ise
        // önceki gerçek kullanıcı mesajı — eşleşmezse sunucu yeni bir `voice`
        // satırı ekler (yinelenen balon hatası). Eski/eksik kayıtlar için `text`e düş.
        let serverRequestText = messages[idx].pendingVoiceRequestText ?? text
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

                await completeTypingDelay(forReplyLength: result.reply.count, since: bubbleStartedAt)

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
                let voiceRemoteURL: URL?
                switch ttsResult {
                case .success(let data, let tokenBalance, let url):
                    audioData = data
                    voiceRemoteURL = url
                    handleTokenBalance(tokenBalance)
                case .insufficientTokens:
                    generatingVoiceMessageIDs.remove(messageID)
                    presentInsufficientTokensPaywall()   // uyarı yok, paywall aç
                    isSending = false
                    return
                case .notEntitled:
                    // Sunucu "ses Pro+ gerektirir" dedi (istemci kapısı aşılmış ya da
                    // tier bayat) — hata değil, yükseltme paywall'ı.
                    generatingVoiceMessageIDs.remove(messageID)
                    showPaywall = true
                    isSending = false
                    Task { await tokenStore?.refresh() }  // ücretlendirilmedi → düzelt
                    return
                case .failure:
                    generatingVoiceMessageIDs.remove(messageID)
                    errorMessage = String(localized: "Voice message failed to generate.")
                    isSending = false
                    Task { await tokenStore?.refresh() }  // ücretlendirilmedi → düzelt
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
                    messages[finalIdx].voiceRemoteURL = voiceRemoteURL
                    messages[finalIdx].pendingVoiceRequest = nil
                    messages[finalIdx].pendingVoiceRequestText = nil
                }
                LocalConversationStore.shared.updateMessage(id: messageID, for: character.id) { msg in
                    msg.content = cleanedReply
                    msg.voiceLocalPath = savedPath
                    msg.voiceDuration = duration
                    msg.pendingVoiceRequest = nil
                    msg.pendingVoiceRequestText = nil
                }
                LocalConversationStore.shared.refreshDetectedLanguage(for: character.id)
                store?.chatCache[character.id] = realMessages()
                generatingVoiceMessageIDs.remove(messageID)
                updateCache()

                // Sesi SUNUCUDA sakla: aynı requestText'li "kilitli" (voice_pending)
                // satır gerçek sese (kind=voice, content=URL) çevrilir. Böylece chate
                // tekrar girince METİN değil SES balonu görünür (foto ile simetrik).
                await service.saveVoiceMessage(character: character, requestText: serverRequestText, url: voiceRemoteURL?.absoluteString)

                applyPostReplyEffects(gotPhoto: nil, stored: stored)
            } catch {
                generatingVoiceMessageIDs.remove(messageID)
                if isInsufficientTokensError(error) {
                    presentInsufficientTokensPaywall()   // uyarı yok, paywall aç (kendi içinde refresh() var)
                } else {
                    errorMessage = error.localizedDescription
                    Task { await tokenStore?.refresh() }  // ücretlendirilmedi → düzelt
                }
            }
            isSending = false
        }
    }

    /// Fotoğraf İSTEĞİ. Kullanıcı talebi: foto düğmesine basınca karakter METİN
    /// cevabı VERMEZ (özellikle boş girdide "fotoğraf gönder" metnini gönderip
    /// "düğmeye bas" gibi tuhaf cevap alma sorunu) — bunun yerine kısa bir
    /// "yazıyor" gösterilir, sonra bulanık "ödeme bekleyen" foto balonu gelir.
    /// GÖRSELİ AÇMAK (balona dokunma) 25 jetondur (bkz. generatePendingImage).
    /// Kullanıcı bir TARİF yazdıysa o mesaj olarak görünür + seçim istemi olur;
    /// boşsa hiç kullanıcı-metni gösterilmez.
    /// "Send me a photo" düğmesi — tek dokunuş. Metinli/tarifli istek YOK
    /// (kullanıcı talebi): kullanıcı mesajı eklenmez, sadece bulanık kilitli
    /// foto balonu düşer; üretim + tahsil o balona dokununca
    /// (bkz. generatePendingImage). Prompt her zaman içsel varsayılan.
    func sendImageRequest() {
        guard !isSending, !isLoadingHistory else { return }
        // Foto PRO özelliği — PRO değilse (kredi yetse bile) PRO paywall aç.
        guard PurchaseService.shared.isPro else { paywallTier = .pro; showPaywall = true; return }
        NotificationScheduler.shared.noteUserSent(character: character)
        messagesSentThisSession += 1
        EventLogger.shared.log("message_sent", ["character_id": character.id, "kind": "image_request"])
        EventLogger.shared.log("feature_used", ["feature": "photo_request"])
        errorMessage = nil
        appendPendingImageBubble(prompt: "a photo of you right now")
    }

    /// Kilitli foto balonunu ekler — hem düğme akışı (`sendImageRequest`) hem
    /// de Grok'un düz metinde foto isteğini anlayıp [[SEND_PHOTO: ...]]
    /// işareti döndürdüğü otomatik akış (bkz. `send()`, MEDIA_REQUEST_RULE)
    /// AYNI bu fonksiyonu çağırır — üretim/kilit/maliyet mantığı TEK yerde,
    /// iki yol arasında hiçbir fark yok (bkz. kullanıcı talebi: "düğmeye
    /// basılmış gibi davranmalı").
    /// `send()`'in sonunda çağrılır — sunucu `autoMedia` döndüyse (Grok düz
    /// metinde foto/ses isteğini anladıysa) düğmeyle AYNI kilitli-balon akışını
    /// tetikler. Hak yoksa (isPro/canUseVoice) SESSİZCE atlanır — bu kullanıcının
    /// kendi bastığı bir düğme değil, AI'ın kendi kararı; davetsiz bir paywall
    /// sheet'i açmak yanlış an'da rahatsız edici olurdu (bkz. kullanıcı talebi
    /// — sadece üretim/kilit/maliyet mantığının düğmeyle AYNI kalması istendi,
    /// paywall'ın kendiliğinden açılması istenmedi).
    private func triggerAutoMediaIfNeeded(_ media: WireAutoMedia?) {
        guard let media else { return }
        switch media.kind {
        case "photo":
            guard PurchaseService.shared.isPro else { return }
            appendPendingImageBubble(prompt: media.prompt ?? "a photo of you right now")
        case "voice":
            guard PurchaseService.shared.canUseVoice else { return }
            appendPendingVoiceBubble(requestText: String(localized: "Send me a voice"))
        default:
            break
        }
    }

    private func appendPendingImageBubble(prompt: String) {
        Task {
            await handleWakeUpIfAsleep()
            // "Fotoğraf hazırlıyor" hissi: kısa yazıyor balonu → sonra bulanık
            // foto balonu. Foto isteğine METİN cevabı verilmez (foto + açılınca
            // gelen caption yanıttır).
            await pause(TypingTiming.randomStartDelay())
            showsTypingBubble = true
            store?.setTyping(character.id, true)
            await pause(0.9)
            showsTypingBubble = false
            store?.setTyping(character.id, false)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
                messages.append(Message(role: .assistant, content: "", pendingImagePrompt: prompt))
            }
            updateCache()
            // Açılmamış (kilitli) foto'yu SUNUCUDA sakla — üretmeden çıkıp girse
            // bile "üret" balonu olarak geri gelsin (bkz. chat/index.ts photoMessage).
            await service.savePhotoMessage(character: character, prompt: prompt, url: nil)
        }
    }

    /// Bir "ödeme bekleyen" foto balonuna dokununca — 25 token tahsil edip
    /// gerçek görseli üretir. Balon, görsel CİHAZA TAM İNENE kadar (sadece
    /// URL dönmesi değil) "üretiliyor" durumunda kalır — `ImageCache.prefetch`
    /// tamamlanmadan `imageURL` set edilmez, yoksa CachedImage 1-2 saniye
    /// boş görünürdü (bkz. kullanıcı talebi).
    func generatePendingImage(for messageID: UUID) {
        // Foto PRO özelliği — PRO değilse üretme, PRO paywall aç.
        guard PurchaseService.shared.isPro else { paywallTier = .pro; showPaywall = true; return }
        guard let idx = messages.firstIndex(where: { $0.id == messageID }),
              let prompt = messages[idx].pendingImagePrompt,
              messages[idx].imageURL == nil,
              !generatingImageMessageIDs.contains(messageID)
        else { return }
        // Token yetmiyorsa HİÇ loading gösterme — doğrudan paywall/coin mağazası.
        guard hasTokensOrPaywall(cost: 25) else { return }
        deductBadgeOptimistically(25)

        generatingImageMessageIDs.insert(messageID)
        isSending = true
        errorMessage = nil

        Task {
            await handleWakeUpIfAsleep()
            // NOT: Kilit açılırken (foto üretilirken) ALTA "yazıyor" balonu
            // GÖSTERİLMEZ — foto balonu kendi yerinde spinner'la üretilir. "Yazıyor"
            // yalnızca foto GELDİKTEN sonra, caption turu için çıkar (aşağıda).
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
                LocalConversationStore.shared.updateMessage(id: messageID, for: character.id) { msg in
                    msg.imageURL = imageResult.url
                    msg.pendingImagePrompt = nil
                }
                store?.chatCache[character.id] = realMessages()
                generatingImageMessageIDs.remove(messageID)
                handleTokenBalance(imageResult.tokenBalance)

                // Üretilen fotoğrafı SUNUCUDA sakla: aynı prompt'lu "açılmamış"
                // (image_pending) satır gerçek görsele (kind=image) çevrilir; yoksa
                // yeni image satırı eklenir (bkz. chat/index.ts photoMessage). Böylece
                // hem açılmamış hem açılmış foto reload sonrası doğru durumda görünür.
                // Caption turundan ÖNCE saklanır ki sıralama doğru olsun.
                await service.savePhotoMessage(
                    character: character, prompt: prompt, url: imageResult.url.absoluteString
                )

                // Foto-sonrası metin tepkisi (IMAGE_CAPTION_RULE) KALDIRILDI —
                // kullanıcı talebi 2026-08-26: "weird", istenmiyor. Foto reveal
                // artık başka hiçbir mesaj eklemeden burada biter.
                isSendingImageReply = false
                applyPostReplyEffects(gotPhoto: imageResult.url, stored: stored)
            } catch {
                generatingImageMessageIDs.remove(messageID)
                if isInsufficientTokensError(error) {
                    presentInsufficientTokensPaywall()   // uyarı yok, paywall aç (kendi içinde refresh() var)
                } else if isNoPhotoError(error) {
                    // Havuzda gönderilebilir foto yok — bekleyen balonu kaldır ve
                    // kullanıcıya net bir hata göster (Grok'tan üretim YOK).
                    messages.removeAll { $0.id == messageID }
                    updateCache()
                    errorMessage = String(localized: "I don't have a photo to send you right now.")
                    Task { await tokenStore?.refresh() }  // ücretlendirilmedi → düzelt
                } else {
                    errorMessage = error.localizedDescription
                    // Hâlâ ANINDA düşürülmüş bakiyeyi taşıyor olabiliriz (görsel
                    // üretimi bitip caption turu başarısız olmuş olabilir) —
                    // ya da hiç ücretlendirilmemiş olabilir; ikisinde de gerçek
                    // bakiyeyle düzeltmek güvenli (refresh salt-okunur senkron).
                    Task { await tokenStore?.refresh() }
                }
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
            await pause(TypingTiming.randomStartDelay())
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

            await completeTypingDelay(forReplyLength: trimmed.count, since: bubbleStartedAt)
            showsTypingBubble = false
            store?.setTyping(character.id, false)

            let replyMsg = Message(role: .assistant, content: trimmed)
            messages.append(replyMsg)
            LocalConversationStore.shared.appendMessage(replyMsg, for: character.id, defaultLevel: relationshipLevel, defaultLevelProgress: levelProgress)
            LocalConversationStore.shared.refreshDetectedLanguage(for: character.id)
            store?.chatCache[character.id] = realMessages()
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

        // Profilin ANINDA görmesi için paylaşılan canlı cache'e yaz (kalıcı
        // kaydın arka plan kuyruğunu beklemeden).
        store?.setLevel(character.id, level: relationshipLevel, progress: levelProgress)

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
            guard let self else { return }
            await MainActor.run {
                LocalConversationStore.shared.updateSummary(
                    for: characterId,
                    summary: result.summary,
                    summarizedCount: windowStart,
                    schedule: result.schedule
                )
                self.refreshCurrentActivity()
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
        // UYKU ÖZELLİĞİ KAPATILDI (kullanıcı talebi 2026-08-26) — "Asleep"/"Uyuyor"
        // gibi uyku bloğu etiketleri artık UI'da GÖSTERİLMEZ (header "Online"
        // görünmeye devam eder). Kod SİLİNMEDİ, sadece bu blok UI'a yansımıyor.
        guard !block.isSleep else {
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
        // UYKU ÖZELLİĞİ YENİDEN AÇILDI (kullanıcı talebi 2026-08-31). Artık
        // SADECE CharacterSleepState.isEffectivelyAsleep true döndüğünde
        // (yani manualSleepAt konuşma-içi anlaşmayla set edilmişse) tetiklenir
        // — program/rutin artık hiçbir zaman tek başına "uyuyor" saydırmaz.
        let stored = LocalConversationStore.shared.load(for: character.id)

        if stored?.wokenUpAt != nil {
            // Zaten uyandırılmış — gecikmeyi atla, sadece uyku-öncesi
            // zamanlayıcıyı sıfırla (konuşma devam ettiği sürece uyanık kal).
            NotificationScheduler.shared.scheduleSleepyGoodnight(for: character, from: Date())
            return
        }

        guard CharacterSleepState.isEffectivelyAsleep(stored: stored) else { return }

        await pause(5)
        currentActivity = (
            label: String(localized: "Just woke up"),
            detail: "just woke up from being asleep, still a little groggy, texting from bed"
        )
        await pause(5)

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
            guard let self else { return }
            await MainActor.run { self.refreshCurrentActivity() }
        }
    }

    /// `ChatView`'in `.task` içinden çağrılır — view kaybolunca SwiftUI
    /// otomatik iptal eder, elle Timer yönetimine gerek yok.
    func startActivityRefreshLoop() async {
        while !Task.isCancelled {
            refreshCurrentActivity()
            await pause(60)
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
        // Bellek-içi önbellek ANINDA (main) güncellenir — hemen ardından okuyan
        // main-actor kodu (loadHistory'nin önbellek dalı, ChatListView) taze görsün.
        store?.chatCache[character.id] = real

        // Kalıcılaştırma her mesaj eklemede senkron olarak MainActor'da çalışıp
        // UI'ı takıyordu (bkz. çağrı yerleri: send/sendUserVoice/... hepsi bunu
        // çağırır). Değer anlık görüntüsü (snapshot) yakalanır ve load+build+save
        // seri arka plan kuyruğunda yapılır — böylece gönderimde hitch olmaz,
        // yarış (race) da olmaz (snapshot değer-tipi + sıralı kuyruk).
        let characterID = character.id
        let snapshot = real
        let level = relationshipLevel
        let progress = levelProgress
        let counter = msgCounter
        Self.persistQueue.async {
            let stored = LocalConversationStore.shared.load(for: characterID)
            let updated = LocalConversationStore.Stored(
                messages: snapshot,
                xp: stored?.xp ?? 0,
                level: level,
                summary: stored?.summary ?? "",
                summarizedCount: stored?.summarizedCount ?? 0,
                msgCounter: counter ?? stored?.msgCounter ?? 0,
                levelProgress: progress,
                detectedLanguage: ConversationLanguage.resolve(
                    latestAssistantText: snapshot.last(where: { $0.role == .assistant })?.content,
                    previouslyDetected: stored?.detectedLanguage
                ),
                schedule: stored?.schedule,
                wokenUpAt: stored?.wokenUpAt,
                manualSleepAt: stored?.manualSleepAt
            )
            LocalConversationStore.shared.save(updated, for: characterID)
        }
    }
}
