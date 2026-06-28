//
//  ChatService.swift
//  Supabase Edge Function ("chat") ile konuşur.
//  Bellek SUNUCUDA: telefon tüm geçmişi göndermez.
//   - loadHistory: uygulama açılınca geçmiş sohbeti çeker
//   - send: sadece YENİ mesajı gönderir, cevabı alır
//

import Foundation

private struct ChatRequest: Codable {
    let characterId: String
    let systemPrompt: String
    let userMessage: String?
}

private struct WireMessage: Codable {
    let role: String
    let content: String
}

private struct ChatResponse: Codable {
    let conversationId: String?
    let reply: String?
    let history: [WireMessage]?
    // İlişki / XP sistemi (sunucu hesaplar)
    let xp: Int?
    let level: Int?
    let leveledUp: Bool?
    let photoUrl: String?
}

/// Geçmiş yükleme sonucu — mesajlar + güncel ilişki durumu.
struct ChatHistory {
    let messages: [Message]
    let level: Int
    let xp: Int
}

/// Mesaj gönderme sonucu — cevap + güncel ilişki durumu.
struct ChatReply {
    let reply: String
    let level: Int
    let xp: Int
    let leveledUp: Bool
    let photoURL: URL?
}

enum ChatServiceError: Error, LocalizedError {
    case badStatus(Int, String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let body): return "Sunucu hatası (\(code)): \(body)"
        case .decoding: return "Cevap çözümlenemedi."
        }
    }
}

struct ChatService {
    /// Uygulama açılınca o karakterle geçmiş sohbeti + güncel ilişki durumunu yükler.
    func loadHistory(character: Character) async throws -> ChatHistory {
        let resp = try await call(character: character, userMessage: nil)
        let messages = (resp.history ?? []).map {
            Message(role: ChatRole(rawValue: $0.role) ?? .assistant, content: $0.content)
        }
        return ChatHistory(messages: messages, level: resp.level ?? 1, xp: resp.xp ?? 0)
    }

    /// Yeni mesaj gönderir; cevabı + güncel ilişki durumunu döner. (Geçmiş sunucuda.)
    func send(character: Character, userMessage: String) async throws -> ChatReply {
        let resp = try await call(character: character, userMessage: userMessage)
        return ChatReply(
            reply: resp.reply ?? "",
            level: resp.level ?? 1,
            xp: resp.xp ?? 0,
            leveledUp: resp.leveledUp ?? false,
            photoURL: resp.photoUrl.flatMap(URL.init(string:))
        )
    }

    // MARK: - Ortak istek

    private func call(character: Character, userMessage: String?) async throws -> ChatResponse {
        // İlk deneme; 401 (token expired) gelirse yenileyip bir kez daha dene.
        do {
            return try await perform(character: character, userMessage: userMessage)
        } catch ChatServiceError.badStatus(let code, _) where code == 401 {
            _ = await SupabaseAuth.recover()
            return try await perform(character: character, userMessage: userMessage)
        }
    }

    private func perform(character: Character, userMessage: String?) async throws -> ChatResponse {
        var request = URLRequest(url: Config.chatFunctionURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Oturum açmış kullanıcının token'ı (fonksiyon user id'yi buradan alır).
        let bearer = UserDefaultsManager.shared.accessToken ?? Config.supabaseAnonKey
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")

        let body = ChatRequest(
            characterId: character.id.uuidString.lowercased(),
            systemPrompt: character.systemPrompt,
            userMessage: userMessage
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatServiceError.decoding
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ChatServiceError.badStatus(http.statusCode, text)
        }
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            throw ChatServiceError.decoding
        }
        return decoded
    }
}
