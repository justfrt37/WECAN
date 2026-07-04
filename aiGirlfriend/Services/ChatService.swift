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
            photoURL: resp.photoUrl.flatMap(URL.init(string:))
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
        voiceChat: Bool = false
    ) async throws -> ChatReply {
        let wireHistory = localMessages
            .filter { $0.imageURL == nil }
            .suffix(20)
            .map { WireHistoryMessage(role: $0.role.rawValue, content: $0.content) }
        let resp = try await perform(
            character: character,
            userMessage: userMessage,
            extra: .localHistory(wireHistory, summary: summary.isEmpty ? nil : summary),
            level: level,
            lastMessageAt: lastMessageAt,
            voiceChat: voiceChat
        )
        return ChatReply(
            reply: resp.reply ?? "",
            level: resp.level ?? level,
            photoURL: resp.photoUrl.flatMap(URL.init(string:))
        )
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
        existingSummary: String
    ) async throws -> String {
        let wire = messagesToFold
            .filter { $0.imageURL == nil }
            .map { WireHistoryMessage(role: $0.role.rawValue, content: $0.content) }
        let resp = try await perform(
            character: character,
            userMessage: nil,
            extra: .summarize(wire, existing: existingSummary)
        )
        return resp.summary ?? existingSummary
    }

    // MARK: - İç yardımcılar

    private enum RequestExtra {
        case none
        case clear
        case localHistory([WireHistoryMessage], summary: String?)
        case summarize([WireHistoryMessage], existing: String)
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
        voiceChat: Bool = false
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
            voiceChat: voiceChat
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
