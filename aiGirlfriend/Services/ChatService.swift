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
}

private struct WireMessage: Codable {
    let role: String
    let content: String
}

private struct ChatResponse: Codable {
    let conversationId: String?
    let reply: String?
    let history: [WireMessage]?
    let xp: Int?
    let level: Int?
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
}

struct ChatReply {
    let reply: String
    let level: Int      // sunucunun sakladığı (istemcinin bir önceki turda gönderdiği) seviye
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

    /// Preset karakter: sunucudan geçmiş yükle.
    func loadHistory(character: Character) async throws -> ChatHistory {
        let resp = try await call(character: character, userMessage: nil)
        let messages = (resp.history ?? []).map {
            Message(role: ChatRole(rawValue: $0.role) ?? .assistant, content: $0.content)
        }
        return ChatHistory(messages: messages, level: resp.level ?? 1, xp: resp.xp ?? 0)
    }

    /// Preset karakter: yeni mesaj gönder.
    /// `lastMessageAt`: sohbetteki bir önceki mesajın zamanı — sunucu bunu şu anki
    /// zamanla karşılaştırıp bota doğal bir zaman/boşluk bağlamı verir.
    func send(character: Character, userMessage: String, level: Int, lastMessageAt: Date? = nil) async throws -> ChatReply {
        let resp = try await call(character: character, userMessage: userMessage, level: level, lastMessageAt: lastMessageAt)
        return ChatReply(
            reply: resp.reply ?? "",
            level: resp.level ?? level,
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
            level: resp.level ?? level,
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
            level: resp.level ?? level,
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
        var request = URLRequest(url: Config.chatImageFunctionURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bearer = UserDefaultsManager.shared.accessToken ?? Config.supabaseAnonKey
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        let wireHistory = localMessages
            .filter { $0.imageURL == nil && $0.localImagePath == nil && !$0.isPending }
            .suffix(20)
            .map { WireHistoryMessage(role: $0.role.rawValue, content: $0.content) }
        request.httpBody = try JSONEncoder().encode(
            ChatImageRequest(
                characterId: character.id.uuidString.lowercased(),
                prompt: prompt,
                history: wireHistory,
                summary: summary.isEmpty ? nil : summary,
                currentActivity: currentActivity
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatServiceError.decoding }
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

    /// "Sohbeti Temizle" — sunucudaki conversation/messages satırlarını siler
    /// (cascade ile memories de gider). İstemci ayrıca kendi yerel kopyasını temizler.
    func clearConversation(character: Character) async throws {
        _ = try await perform(character: character, userMessage: nil, extra: .clear)
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
        case clear
        case localHistory([WireHistoryMessage], summary: String?)
        case summarize([WireHistoryMessage], existing: String)
        case photoDownloadReaction([WireHistoryMessage], summary: String?, photoURL: String)
    }

    private func call(character: Character, userMessage: String?, level: Int? = nil, lastMessageAt: Date? = nil) async throws -> ChatResponse {
        do {
            return try await perform(character: character, userMessage: userMessage, extra: .none, level: level, lastMessageAt: lastMessageAt)
        } catch ChatServiceError.badStatus(let code, _) where code == 401 {
            _ = await SupabaseAuth.recover()
            return try await perform(character: character, userMessage: userMessage, extra: .none, level: level, lastMessageAt: lastMessageAt)
        }
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
        var request = URLRequest(url: Config.chatFunctionURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bearer = UserDefaultsManager.shared.accessToken ?? Config.supabaseAnonKey
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")

        var clearConversation: Bool? = nil
        var clientHistory: [WireHistoryMessage]? = nil
        var localSummary: String? = nil
        var summarizeMessages: [WireHistoryMessage]? = nil
        var existingSummary: String? = nil
        var photoDownloadReaction: Bool? = nil
        var photoURL: String? = nil

        switch extra {
        case .none:
            break
        case .clear:
            clearConversation = true
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
            systemPrompt: character.systemPrompt,
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
            imageRedirected: imageRedirected
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatServiceError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw ChatServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            throw ChatServiceError.decoding
        }
        return decoded
    }
}
