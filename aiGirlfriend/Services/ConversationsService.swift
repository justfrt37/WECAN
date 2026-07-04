//
//  ConversationsService.swift
//  Sohbet listesi: konuşmalar + her konuşmanın son mesajı.
//  RLS: kullanıcı yalnızca kendi conversations/messages satırlarını okur.
//

import Foundation

struct ConversationSummary: Codable {
    let id: UUID
    let characterID: UUID
    let updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case characterID = "character_id"
        case updatedAt = "updated_at"
    }
}

struct LastMessage: Codable {
    let conversationID: UUID
    let content: String
    let role: String
    let createdAt: String

    var isUser: Bool { role == "user" }

    var date: Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt)
    }

    private enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case content, role
        case createdAt = "created_at"
    }
}

struct ConversationsService {
    /// Kullanıcının konuşmaları (en yeni üstte).
    func fetchConversations() async -> [ConversationSummary] {
        let url = "\(Config.supabaseURL)/rest/v1/conversations?select=id,character_id,updated_at&order=updated_at.desc"
        return await get(url) ?? []
    }

    /// Tüm mesajlar (RLS ile yalnızca kullanıcınınki), en yeni üstte.
    func fetchAllMessages() async -> [LastMessage] {
        let url = "\(Config.supabaseURL)/rest/v1/messages?select=conversation_id,content,role,created_at&order=created_at.desc"
        return await get(url) ?? []
    }

    private func get<T: Decodable>(_ endpoint: String) async -> T? {
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        let bearer = UserDefaultsManager.shared.accessToken ?? Config.supabaseAnonKey
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
