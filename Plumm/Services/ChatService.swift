//
//  ChatService.swift
//  Supabase Edge Function ("chat") ile konuşur.
//

import Foundation

private struct WireHistoryMessage: Codable {
    let role: String
    let content: String
}

private struct ChatRequest: Codable {
    let characterId: String
    let systemPrompt: String
    let userMessage: String?
    let clientHistory: [WireHistoryMessage]?
    let localSummary: String?
    let summarizeMessages: [WireHistoryMessage]?
    let existingSummary: String?
    let level: Int?   // istemci taraflı hesaplanan güncel seviye — sunucu sadece saklar
    // Zaman farkındalığı — epoch ms cinsinden. Sunucu bunlarla mesaj arasındaki
    // boşluğu ve günün saatini hesaplayıp bota doğal bir zaman bağlamı verir.
    let lastMessageAt: Double?
    let clientNow: Double?
    let tzOffsetMinutes: Int?
    /// "Clear Chat" — sunucudaki conversation/messages satırlarını siler.
    let clearConversation: Bool?
    /// true ise cevap sesli mesaj olarak seslendirilecek — sunucu Grok'a
    /// ElevenLabs v3 ses etiketleri (ör. [laughs], [whispers]) eklemesini söyler.
    let voiceChat: Bool?
    /// true ise Grok'a "az önce fotoğraf gönderdin, istersen kısa bir tepki yaz,
    /// istemiyorsan [[no_caption]] yaz" talimatı eklenir (bkz. chat-image akışı).
    let imageReactionChat: Bool?
    /// Günlük rutinden "şu an ne yapıyor" bloğunun ayrıntılı açıklaması —
    /// bkz. ChatViewModel.currentActivity, chat/index.ts GÜNLÜK RUTİN notu.
    let currentActivity: String?
    /// Özetleme modunda: istemcinin şu an bildiği rutin, sunucu bunu
    /// gözden geçirip günceller (bkz. generateLocalSummary).
    let previousSchedule: CharacterSchedule?
    /// true ise bu bir fotoğraf-indirme tepkisi çağrısıdır — userMessage yok,
    /// sunucu generated_photos'ta bu url'i arayıp özel/mahrem VE henüz tepki
    /// verilmemişse Grok'a bir kere tepki yazdırır (bkz. chat/index.ts).
    let photoDownloadReaction: Bool?
    let photoURL: String?
    /// İstemci ScheduleLookup ile hesaplar — gerçek yatma saatine 1 saatten
    /// yakın mı (bkz. ChatViewModel.send, chat/index.ts sleepRule).
    let nearSleepTime: Bool?
    /// Kullanıcı BU turda bota kendi fotoğrafını gönderdiyse, küçültülmüş
    /// base64 JPEG (bkz. UserPhotoStore.base64JPEG). SADECE bu tek turda
    /// gönderilir, hiçbir yerde saklanmaz/geçmişe tekrar sızmaz.
    let userImageBase64: String?
    /// true ise az önce üretilen fotoğraf reddedilip yumuşatılmış bir
    /// versiyonla değiştirildi (bkz. chat-image/index.ts redirected alanı) —
    /// Grok normal foto tepkisi yerine "bunu şimdi yapamam ama bunu
    /// gönderebilirim" tarzı doğal bir yönlendirme cevabı yazmalı (bkz.
    /// chat/index.ts IMAGE_REDIRECT_RULE).
    let imageRedirected: Bool?
    /// Review Mode (App Store inceleme) açıkken true — sunucu flört direktifini
    /// atlayıp platonik/arkadaş-canlısı bir direktif uygular (bkz. ReviewModeService,
    /// chat/index.ts). Varsayılan nil (memberwise init'i bozmaz).
    var reviewMode: Bool? = nil
    /// "Clear Chat" seçenekleri — sadece `clearConversation: true` ile
    /// birlikte anlamlı. bkz. ClearChatOptionsSheet, chat/index.ts clear branch.
    let keepLevel: Bool?
    let keepMemories: Bool?
    let keepBehaviors: Bool?
}

private struct WireMessage: Codable {
    let role: String
    let content: String
    /// "text" | "image" | "voice" — üretilmiş foto mesajları reload sonrası
    /// yeniden görünsün diye (bkz. Message.fromServer). Eski satırlarda nil.
    let kind: String?
}

private struct WireReplySegment: Codable {
    let text: String
    let delaySeconds: Double
}

/// One paced bubble of a bot reply — see chat/index.ts parseReplySegments.
/// `delaySeconds` for the FIRST segment is always 0 (existing typing-bubble
/// timing already covers it); later segments show the typing indicator for
/// `delaySeconds` before appearing.
struct ReplySegment: Codable, Hashable {
    let text: String
    let delaySeconds: Double
}

private struct ChatResponse: Codable {
    let conversationId: String?
    let reply: String?
    /// Paced multi-bubble breakdown of `reply` (see DRAMATIC_PACING_RULE /
    /// parseReplySegments server-side). Absent or empty for voice/image-
    /// reaction turns and any older response shape — callers must fall back
    /// to a single bubble built from `reply` in that case.
    let replySegments: [WireReplySegment]?
    let history: [WireMessage]?
    let xp: Int?
    let level: Int?
    /// Güncel seviyenin ilerleme oranı (0..1) — SUNUCUDA hesaplanır (bkz.
    /// chat/index.ts applyRelationshipGain). İstemci sadece gösterir.
    let levelProgress: Double?
    let leveledUp: Bool?
    let photoUrl: String?
    let summary: String?   // özetleme modunda döner
    let schedule: CharacterSchedule?   // özetleme modunda döner (rafine edilmiş rutin)
    let wentToSleep: Bool?
    /// Bu turda tahsil edilen token sonrası bakiye — bkz. chat/index.ts
    /// chargeOrReject. voiceChat/imageReactionChat turlarında (kendi
    /// fonksiyonlarında zaten tahsil edildiği için) nil gelir.
    let tokenBalance: Int?
}

struct ChatHistory {
    let messages: [Message]
    let level: Int
    let xp: Int
    /// Güncel seviyenin ilerleme oranı (0..1) — SUNUCUDA hesaplanır. Sohbet
    /// açılışında üst bardaki halka + seviye doğru göstersin diye döner.
    let levelProgress: Double?
}

struct ChatReply {
    let reply: String
    /// See `ChatResponse.replySegments`.
    let replySegments: [ReplySegment]?
    let level: Int      // SUNUCUDA hesaplanan güncel seviye (istemci sadece gösterir)
    let levelProgress: Double?   // güncel seviyenin ilerleme oranı (0..1), sunucudan
    let photoURL: URL?
    /// true ise karakter bu turda gerçekten uyumayı kabul etti (bkz.
    /// ChatViewModel.send, chat/index.ts classifySleepAgreement).
    let wentToSleep: Bool
    /// bkz. ChatResponse.tokenBalance.
    let tokenBalance: Int?
}

enum ChatServiceError: Error, LocalizedError {
    case badStatus(Int, String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let body): return "Server error (\(code)): \(body)"
        case .decoding: return "Couldn't parse the response."
        }
    }
}

private struct AddNoteRequest: Codable {
    let characterId: String
    let kind: String
    let content: String
}

private struct AddNoteResponse: Codable {
    let ok: Bool?
    let error: String?
}

struct ChatService {
    /// "Anı Ekle" / "Davranış Ekle" — karaktere kalıcı bir not ekler (Grok ile doğrulanır).
    /// Sunucu reddederse (geçersiz içerik) `false` döner; ağ/decode hatasında throw eder.
    @discardableResult
    func addCharacterNote(characterId: UUID, kind: String, content: String) async throws -> Bool {
        var request = URLRequest(url: Config.addCharacterNoteFunctionURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bearer = UserDefaultsManager.shared.accessToken ?? Config.supabaseAnonKey
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(
            AddNoteRequest(characterId: characterId.uuidString.lowercased(), kind: kind, content: content)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatServiceError.decoding }
        if (200..<300).contains(http.statusCode) {
            let decoded = try? JSONDecoder().decode(AddNoteResponse.self, from: data)
            return decoded?.ok ?? true
        }
        // Server rejected (e.g. Grok flagged the content as injection) — not a network
        // error, just "didn't save". Caller treats this the same as success (silent dismiss).
        return false
    }

    private struct InjectProactivePayload: Codable {
        let kind: String
        let text: String
        let createIfMissing: Bool
        /// Saklanacak mesajın DB `kind`'i ("text" | "image"). Üretilmiş fotoğraf
        /// mesajlarını kalıcılaştırmak için "image" gönderilir (bkz. generatePendingImage).
        let messageKind: String?
    }
    private struct InjectProactiveRequest: Codable {
        let characterId: String
        let systemPrompt: String
        let injectProactive: InjectProactivePayload
    }
    private struct InjectProactiveResponse: Codable {
        let injected: Bool?
        let conversationId: String?
    }

    /// Bir asistan mesajını (proaktif bildirim satırı veya onboarding ilk-selamı)
    /// SUNUCUDA saklar (bkz. chat/index.ts injectProactive). "Sıfır yerel":
    /// mesaj artık yerele değil sunucuya yazılır → reinstall sonrası ve sohbet
    /// listesinde sunucudan görünür. `createIfMissing` yalnızca ilk-temas
    /// (liked / firstHello) için true — silinmiş sohbeti DİRİLTMEMEK için diğer
    /// bildirimlerde false (var olmayan sohbete yazmaz). Dönen: mesaj eklendi mi.
    @discardableResult
    func injectProactiveMessage(character: Character, kind: String, text: String, createIfMissing: Bool, messageKind: String = "text") async -> Bool {
        var request = URLRequest(url: Config.chatFunctionURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bearer = UserDefaultsManager.shared.accessToken ?? Config.supabaseAnonKey
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        guard let body = try? JSONEncoder().encode(InjectProactiveRequest(
            characterId: character.id.uuidString.lowercased(),
            systemPrompt: character.systemPrompt,
            injectProactive: InjectProactivePayload(kind: kind, text: text, createIfMissing: createIfMissing, messageKind: messageKind)
        )) else { return false }
        request.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return false }
        let decoded = try? JSONDecoder().decode(InjectProactiveResponse.self, from: data)
        return decoded?.injected ?? false
    }

    private struct PhotoMessagePayload: Codable {
        let prompt: String
        let url: String?
    }
    private struct PhotoMessageRequest: Codable {
        let characterId: String
        let systemPrompt: String
        let photoMessage: PhotoMessagePayload
    }

    /// Foto balonunun kalıcı durumunu sunucuya yazar (bkz. chat/index.ts
    /// photoMessage). `url == nil` → "açılmamış/kilitli" foto sakla (kullanıcı
    /// isteği attı, henüz üretmedi); `url != nil` → o pending satırı gerçek
    /// görsele çevir. Böylece açılmamış foto da chate tekrar girince görünür.
    @discardableResult
    func savePhotoMessage(character: Character, prompt: String, url: String?) async -> Bool {
        var request = URLRequest(url: Config.chatFunctionURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bearer = UserDefaultsManager.shared.accessToken ?? Config.supabaseAnonKey
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        guard let body = try? JSONEncoder().encode(PhotoMessageRequest(
            characterId: character.id.uuidString.lowercased(),
            systemPrompt: character.systemPrompt,
            photoMessage: PhotoMessagePayload(prompt: prompt, url: url)
        )) else { return false }
        request.httpBody = body
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return false }
        return true
    }

    private struct VoiceMessagePayload: Codable {
        let requestText: String
        let url: String?
    }
    private struct VoiceMessageRequest: Codable {
        let characterId: String
        let systemPrompt: String
        let voiceMessage: VoiceMessagePayload
    }

    /// Sesli mesaj balonunun kalıcı durumunu sunucuya yazar (bkz. chat/index.ts
    /// voiceMessage — foto ile simetrik). `url == nil` → "açılmamış/kilitli" ses
    /// (kind=voice_pending); `url != nil` → o pending satırı gerçek sese çevir
    /// (kind=voice, content=URL). Böylece reload'da METİN değil SES balonu görünür.
    @discardableResult
    func saveVoiceMessage(character: Character, requestText: String, url: String?) async -> Bool {
        var request = URLRequest(url: Config.chatFunctionURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bearer = UserDefaultsManager.shared.accessToken ?? Config.supabaseAnonKey
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        guard let body = try? JSONEncoder().encode(VoiceMessageRequest(
            characterId: character.id.uuidString.lowercased(),
            systemPrompt: character.systemPrompt,
            voiceMessage: VoiceMessagePayload(requestText: requestText, url: url)
        )) else { return false }
        request.httpBody = body
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return false }
        return true
    }

    /// Preset karakter: sunucudan geçmiş yükle.
    func loadHistory(character: Character) async throws -> ChatHistory {
        let resp = try await call(character: character, userMessage: nil)
        let messages = (resp.history ?? []).map {
            Message.fromServer(role: $0.role, content: $0.content, kind: $0.kind, createdAt: Date())
        }
        return ChatHistory(messages: messages, level: resp.level ?? 1, xp: resp.xp ?? 0, levelProgress: resp.levelProgress)
    }

    /// Preset karakter: yeni mesaj gönder.
    /// `lastMessageAt`: sohbetteki bir önceki mesajın zamanı — sunucu bunu şu anki
    /// zamanla karşılaştırıp bota doğal bir zaman/boşluk bağlamı verir.
    func send(character: Character, userMessage: String, level: Int, lastMessageAt: Date? = nil) async throws -> ChatReply {
        let resp = try await call(character: character, userMessage: userMessage, level: level, lastMessageAt: lastMessageAt)
        return ChatReply(
            reply: resp.reply ?? "",
            replySegments: resp.replySegments?.map { ReplySegment(text: $0.text, delaySeconds: $0.delaySeconds) },
            level: resp.level ?? level,
            levelProgress: resp.levelProgress,
            photoURL: resp.photoUrl.flatMap(URL.init(string:)),
            wentToSleep: resp.wentToSleep ?? false,
            tokenBalance: resp.tokenBalance
        )
    }

    /// Kullanıcı karakteri: geçmişi + özeti istemciden gönder; Supabase messages'a yazılmaz.
    /// `level`: istemcinin şu an bildiği (bir önceki turdan hesaplanmış) seviye — sunucu
    /// bunu bu turun direktif/foto uygunluğu kontrolünden SONRA kalıcı olarak saklar.
    /// `lastMessageAt`: sohbetteki bir önceki mesajın zamanı — zaman farkındalığı için.
    /// `voiceChat`: true ise (sesli mesaj isteği, bkz. ChatViewModel.sendVoiceRequest)
    /// sunucu Grok'a ElevenLabs v3 ses etiketleri eklemesini söyler.
    func sendWithLocalHistory(
        character: Character,
        localMessages: [Message],
        summary: String,
        userMessage: String,
        level: Int,
        lastMessageAt: Date? = nil,
        voiceChat: Bool = false,
        imageReactionChat: Bool = false,
        currentActivity: String? = nil,
        nearSleepTime: Bool = false,
        imageRedirected: Bool = false
    ) async throws -> ChatReply {
        let wireHistory = localMessages
            .filter { $0.imageURL == nil && $0.localImagePath == nil && !$0.isPending }
            .suffix(20)
            .map { WireHistoryMessage(role: $0.role.rawValue, content: $0.content) }
        let resp = try await perform(
            character: character,
            userMessage: userMessage,
            extra: .localHistory(wireHistory, summary: summary.isEmpty ? nil : summary),
            level: level,
            lastMessageAt: lastMessageAt,
            voiceChat: voiceChat,
            imageReactionChat: imageReactionChat,
            currentActivity: currentActivity,
            nearSleepTime: nearSleepTime,
            imageRedirected: imageRedirected
        )
        return ChatReply(
            reply: resp.reply ?? "",
            replySegments: resp.replySegments?.map { ReplySegment(text: $0.text, delaySeconds: $0.delaySeconds) },
            level: resp.level ?? level,
            levelProgress: resp.levelProgress,
            photoURL: resp.photoUrl.flatMap(URL.init(string:)),
            wentToSleep: resp.wentToSleep ?? false,
            tokenBalance: resp.tokenBalance
        )
    }

    /// Kullanıcının BOTA gönderdiği fotoğraf — Grok'a vision girişi olarak
    /// gider (bkz. chat/index.ts hasUserPhoto), sadece BU turda, hiçbir yere
    /// kaydedilmez/geçmişe tekrar sızmaz. `userCaption` boşsa sunucuya tek bir
    /// boşluk gönderilir (chat/index.ts'nin `userMessage!` varsayımları için) —
    /// gösterilen balonun caption'ı gerçekten boş kalır, bu sadece wire'da.
    func sendUserPhotoMessage(
        character: Character,
        localMessages: [Message],
        summary: String,
        userCaption: String,
        base64Image: String,
        level: Int,
        lastMessageAt: Date? = nil,
        currentActivity: String? = nil,
        nearSleepTime: Bool = false
    ) async throws -> ChatReply {
        let wireHistory = localMessages
            .filter { $0.imageURL == nil && $0.localImagePath == nil && !$0.isPending }
            .suffix(20)
            .map { WireHistoryMessage(role: $0.role.rawValue, content: $0.content) }
        let wireCaption = userCaption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? " " : userCaption
        let resp = try await perform(
            character: character,
            userMessage: wireCaption,
            extra: .localHistory(wireHistory, summary: summary.isEmpty ? nil : summary),
            level: level,
            lastMessageAt: lastMessageAt,
            currentActivity: currentActivity,
            nearSleepTime: nearSleepTime,
            userImageBase64: base64Image
        )
        return ChatReply(
            reply: resp.reply ?? "",
            replySegments: resp.replySegments?.map { ReplySegment(text: $0.text, delaySeconds: $0.delaySeconds) },
            level: resp.level ?? level,
            levelProgress: resp.levelProgress,
            photoURL: resp.photoUrl.flatMap(URL.init(string:)),
            wentToSleep: resp.wentToSleep ?? false,
            tokenBalance: resp.tokenBalance
        )
    }

    private struct ChatImageRequest: Codable {
        let characterId: String
        let prompt: String
        let history: [WireHistoryMessage]
        let summary: String?
        /// "Şu an ne yapıyor" (bkz. ChatViewModel.currentActivity) — üretilen
        /// fotoğrafın karakterin GERÇEK şu anki durumunu yansıtması için
        /// (ör. kanepede kitap okurken, iş kıyafeti/laboratuvar DEĞİL).
        let currentActivity: String?
    }

    private struct ChatImageResponse: Codable {
        let url: String?
        let error: String?
        /// Orijinal istek reddedildi (içerik politikası) ve sunucu bunun
        /// yerine yumuşatılmış bir versiyon üretti — bkz. chat-image/index.ts
        /// buildSafeFallbackPrompt. `true` ise çağıran taraf normal fotoğraf
        /// tepkisi yerine "bunu şimdi yapamam ama bunu gönderebilirim" tarzı
        /// doğal bir yönlendirme cevabı istemeli (bkz. IMAGE_REDIRECT_RULE).
        let redirected: Bool?
        let tokenBalance: Int?
    }

    struct ChatImageResult {
        let url: URL
        let redirected: Bool
        let tokenBalance: Int?
    }

    /// "Send me a photo" modu — kullanıcının tarifinden xAI ile gerçek bir
    /// fotoğraf üretir (bkz. ChatViewModel.sendImageRequest). `localMessages`/
    /// `summary` — sohbette daha önce kurulmuş gerçekleri (ör. "laboratuvarda
    /// çalışıyorum") görsel üretim promptuna taşımak için, `sendWithLocalHistory`
    /// ile aynı amaçla gönderilir.
    func generateChatImage(character: Character, prompt: String, localMessages: [Message], summary: String, currentActivity: String? = nil) async throws -> ChatImageResult {
        let wireHistory = localMessages
            .filter { $0.imageURL == nil && $0.localImagePath == nil && !$0.isPending }
            .suffix(20)
            .map { WireHistoryMessage(role: $0.role.rawValue, content: $0.content) }
        let bodyData = try JSONEncoder().encode(
            ChatImageRequest(
                characterId: character.id.uuidString.lowercased(),
                prompt: prompt,
                history: wireHistory,
                summary: summary.isEmpty ? nil : summary,
                currentActivity: currentActivity
            )
        )

        // Ortak yürütücü: 401 kurtar+yeniden-dene + auth başlıkları. Default
        // URLSession timeout (60s) yetmiyor — backend'in prompt oluşturucusu +
        // görsel üretimi (yavaş işlerde ara sıra sunucu-taraflı polling) bunu
        // rahatça aşabilir, sunucu başarılı olacakken istemcide sahte timeout
        // oluşuyordu. 150s gözlenen en kötü durumu marjıyla kapsar.
        let (data, http) = try await sendChatRequest(body: bodyData, url: Config.chatImageFunctionURL, timeout: 150)
        guard (200..<300).contains(http.statusCode) else {
            throw ChatServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let decoded = try? JSONDecoder().decode(ChatImageResponse.self, from: data),
              let urlString = decoded.url, let url = URL(string: urlString) else {
            throw ChatServiceError.decoding
        }
        return ChatImageResult(url: url, redirected: decoded.redirected ?? false, tokenBalance: decoded.tokenBalance)
    }

    /// Fotoğraf indirme tepkisi — sadece indirilen fotoğraf özel/mahrem
    /// işaretliyse VE daha önce hiç tepki verilmemişse sunucu bir cevap döner
    /// (bkz. chat/index.ts photoDownloadReaction). `nil` dönerse (foto özel
    /// değil, ya da zaten bir kere tepki verilmiş) çağıran hiçbir şey yapmaz.
    func sendPhotoDownloadReaction(
        character: Character,
        localMessages: [Message],
        summary: String,
        level: Int,
        photoURL: URL
    ) async throws -> String? {
        let wireHistory = localMessages
            .filter { $0.imageURL == nil && $0.localImagePath == nil && !$0.isPending }
            .suffix(20)
            .map { WireHistoryMessage(role: $0.role.rawValue, content: $0.content) }
        let resp = try await perform(
            character: character,
            userMessage: nil,
            extra: .photoDownloadReaction(wireHistory, summary: summary.isEmpty ? nil : summary, photoURL: photoURL.absoluteString),
            level: level
        )
        return resp.reply
    }

    private struct CharacterScheduleRequest: Codable {
        let characterId: String
        let systemPrompt: String
        let interests: [String]
    }

    private struct CharacterScheduleResponse: Codable {
        let schedule: CharacterSchedule?
        let error: String?
    }

    /// İlk günlük rutin üretimi — bkz. ChatViewModel.ensureScheduleGenerated,
    /// sadece cihazda hiç kayıtlı rutin yokken çağrılır.
    func generateInitialSchedule(character: Character) async throws -> CharacterSchedule {
        var request = URLRequest(url: Config.characterScheduleFunctionURL)
        request.httpMethod = "POST"
        // Rutin üretimi bir LLM çağrısı — 20s bazen yetmez, biraz daha cömert.
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bearer = UserDefaultsManager.shared.accessToken ?? Config.supabaseAnonKey
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(
            CharacterScheduleRequest(
                characterId: character.id.uuidString.lowercased(),
                systemPrompt: character.systemPrompt,
                interests: character.interests
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatServiceError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw ChatServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let decoded = try? JSONDecoder().decode(CharacterScheduleResponse.self, from: data),
              let schedule = decoded.schedule else {
            throw ChatServiceError.decoding
        }
        return schedule
    }

    /// "Sohbeti Temizle" — varsayılan (üç bayrak da false) TÜM sunucu verisini
    /// sıfırlar; `keepLevel`/`keepMemories`/`keepBehaviors` true verilirse o
    /// veri korunur (bkz. chat/index.ts clear branch, ClearChatOptionsSheet).
    /// İstemci ayrıca kendi yerel kopyasını temizler (bkz. ChatMaintenance).
    func clearConversation(character: Character, keepLevel: Bool = false, keepMemories: Bool = false, keepBehaviors: Bool = false) async throws {
        _ = try await perform(character: character, userMessage: nil, extra: .clear(keepLevel: keepLevel, keepMemories: keepMemories, keepBehaviors: keepBehaviors))
    }


    /// Eski mesajları özetle (yerel mod için istemci tarafı özetleme).
    func generateLocalSummary(
        character: Character,
        messagesToFold: [Message],
        existingSummary: String,
        previousSchedule: CharacterSchedule?
    ) async throws -> (summary: String, schedule: CharacterSchedule?) {
        let wire = messagesToFold
            .filter { $0.imageURL == nil && $0.localImagePath == nil && !$0.isPending }
            .map { WireHistoryMessage(role: $0.role.rawValue, content: $0.content) }
        let resp = try await perform(
            character: character,
            userMessage: nil,
            extra: .summarize(wire, existing: existingSummary),
            previousSchedule: previousSchedule
        )
        return (resp.summary ?? existingSummary, resp.schedule)
    }

    // MARK: - İç yardımcılar

    private enum RequestExtra {
        case none
        case clear(keepLevel: Bool, keepMemories: Bool, keepBehaviors: Bool)
        case localHistory([WireHistoryMessage], summary: String?)
        case summarize([WireHistoryMessage], existing: String)
        case photoDownloadReaction([WireHistoryMessage], summary: String?, photoURL: String)
    }

    private func call(character: Character, userMessage: String?, level: Int? = nil, lastMessageAt: Date? = nil) async throws -> ChatResponse {
        // 401 kurtar+yeniden-dene artık `perform`/`sendChatRequest` içinde ortak —
        // burada ayrıca sarmalamaya gerek yok (çift kurtarma olmasın).
        return try await perform(character: character, userMessage: userMessage, extra: .none, level: level, lastMessageAt: lastMessageAt)
    }

    private func perform(
        character: Character,
        userMessage: String?,
        extra: RequestExtra = .none,
        level: Int? = nil,
        lastMessageAt: Date? = nil,
        voiceChat: Bool = false,
        imageReactionChat: Bool = false,
        currentActivity: String? = nil,
        previousSchedule: CharacterSchedule? = nil,
        nearSleepTime: Bool = false,
        userImageBase64: String? = nil,
        imageRedirected: Bool = false
    ) async throws -> ChatResponse {
        var clearConversation: Bool? = nil
        var keepLevel: Bool? = nil
        var keepMemories: Bool? = nil
        var keepBehaviors: Bool? = nil
        var clientHistory: [WireHistoryMessage]? = nil
        var localSummary: String? = nil
        var summarizeMessages: [WireHistoryMessage]? = nil
        var existingSummary: String? = nil
        var photoDownloadReaction: Bool? = nil
        var photoURL: String? = nil

        switch extra {
        case .none:
            break
        case .clear(let kl, let km, let kb):
            clearConversation = true
            keepLevel = kl
            keepMemories = km
            keepBehaviors = kb
        case .localHistory(let h, let s):
            clientHistory = h
            localSummary = s
        case .summarize(let msgs, let existing):
            summarizeMessages = msgs
            existingSummary = existing
        case .photoDownloadReaction(let h, let s, let url):
            clientHistory = h
            localSummary = s
            photoDownloadReaction = true
            photoURL = url
        }

        let body = ChatRequest(
            characterId: character.id.uuidString.lowercased(),
            // Review mode açıkken flörtsüz/arkadaş-canlısı prompt (bkz. ReviewModeService).
            systemPrompt: ReviewModeService.systemPrompt(for: character),
            userMessage: userMessage,
            clientHistory: clientHistory,
            localSummary: localSummary,
            summarizeMessages: summarizeMessages,
            existingSummary: existingSummary,
            level: level,
            lastMessageAt: lastMessageAt.map { $0.timeIntervalSince1970 * 1000 },
            clientNow: Date().timeIntervalSince1970 * 1000,
            tzOffsetMinutes: TimeZone.current.secondsFromGMT() / 60,
            clearConversation: clearConversation,
            voiceChat: voiceChat,
            imageReactionChat: imageReactionChat,
            currentActivity: currentActivity,
            previousSchedule: previousSchedule,
            photoDownloadReaction: photoDownloadReaction,
            photoURL: photoURL,
            nearSleepTime: nearSleepTime,
            userImageBase64: userImageBase64,
            imageRedirected: imageRedirected,
            reviewMode: ReviewModeService.isEnabledSnapshot ? true : nil,
            keepLevel: keepLevel,
            keepMemories: keepMemories,
            keepBehaviors: keepBehaviors
        )
        let bodyData = try JSONEncoder().encode(body)

        // 401 (token süresi doldu) tek seferlik kurtar+yeniden-dene ARTIK burada,
        // ortak `perform`ta yaşıyor — böylece bunu çağıran TÜM akışlar
        // (sendWithLocalHistory / sendUserPhotoMessage / sendPhotoDownloadReaction /
        // clear / summarize / loadHistory) token yenilemesinden faydalanır, yoksa
        // süre dolduktan sonraki ilk gönderim kullanıcıya "Server error (401)" olarak
        // sızıyordu. Yeniden-denemede istek TAZE token ile yeniden kurulur.
        let (data, http) = try await sendChatRequest(body: bodyData, url: Config.chatFunctionURL, timeout: 20)
        guard (200..<300).contains(http.statusCode) else {
            throw ChatServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            throw ChatServiceError.decoding
        }
        return decoded
    }

    /// Ortak POST yürütücü: JSON gövdesini gönderir, 401 gelirse bir kez
    /// `SupabaseAuth.recover()` deneyip isteği TAZE erişim jetonuyla yeniden kurup
    /// gönderir. Auth başlıklarını ve açık `timeoutInterval`ı tek yerde uygular —
    /// hem `perform` hem `generateChatImage` bunu kullanır (bkz. fix: 401 sadece
    /// eski `call()`de vardı, doğrudan `perform` çağıranlar bypass ediyordu).
    private func sendChatRequest(body: Data, url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        func attempt() async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let bearer = UserDefaultsManager.shared.accessToken ?? Config.supabaseAnonKey
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
            request.httpBody = body
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ChatServiceError.decoding }
            return (data, http)
        }

        let first = try await attempt()
        guard first.1.statusCode == 401 else { return first }
        _ = await SupabaseAuth.recover()
        return try await attempt()
    }
}
