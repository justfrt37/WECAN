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
    /// "text" | "image" | "voice" — DB `messages.kind` sütunuyla aynı ("voice"
    /// yereldir). Yerel (cihaz) mesajlarından türetilirken medya bayraklarına
    /// göre elle set edilir (bkz. ChatListView.load()).
    let kind: String?

    var isUser: Bool { role == "user" }
    var isImage: Bool { kind == "image" }
    var isVoice: Bool { kind == "voice" }

    var date: Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt)
    }

    init(conversationID: UUID, content: String, role: String, createdAt: String, kind: String? = nil) {
        self.conversationID = conversationID
        self.content = content
        self.role = role
        self.createdAt = createdAt
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case content, role, kind
        case createdAt = "created_at"
    }
}

/// "Sıfır yerel" hidrasyonu için tam konuşma durumu — LocalConversationStore
/// (bellek-içi) her açılışta buradan doldurulur (bkz. CharacterStore.
/// hydrateConversations). Sunucu (migration 009) tek doğru kaynak.
struct ConversationState: Codable {
    let id: UUID
    let characterID: UUID
    let relationshipLevel: Int?
    let levelProgress: Double?
    let summary: String?
    let summarizedCount: Int?
    let schedule: CharacterSchedule?
    let wokenUpAt: String?
    let manualSleepAt: String?
    let ghostedAt: String?
    let detectedLanguage: String?
    let updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case characterID = "character_id"
        case relationshipLevel = "relationship_level"
        case levelProgress = "level_progress"
        case summary
        case summarizedCount = "summarized_count"
        case schedule
        case wokenUpAt = "woken_up_at"
        case manualSleepAt = "manual_sleep_at"
        case ghostedAt = "ghosted_at"
        case detectedLanguage = "detected_language"
        case updatedAt = "updated_at"
    }
}

struct ConversationsService {
    /// Kullanıcının konuşmaları (en yeni üstte).
    func fetchConversations() async -> [ConversationSummary] {
        let url = "\(Config.supabaseURL)/rest/v1/conversations?select=id,character_id,updated_at&order=updated_at.desc"
        return await get(url) ?? []
    }

    /// Tüm konuşma DURUMLARI (seviye/ilerleme/özet/rutin/uyku/dil) — bellek-içi
    /// önbelleği sunucudan tazelemek için (bkz. CharacterStore.hydrateConversations).
    func fetchConversationStates() async -> [ConversationState] {
        let url = "\(Config.supabaseURL)/rest/v1/conversations?select=id,character_id,relationship_level,level_progress,summary,summarized_count,schedule,woken_up_at,manual_sleep_at,ghosted_at,detected_language,updated_at&order=updated_at.desc"
        return await get(url) ?? []
    }

    /// Tüm mesajlar (RLS ile yalnızca kullanıcınınki), en yeni üstte.
    func fetchAllMessages() async -> [LastMessage] {
        let url = "\(Config.supabaseURL)/rest/v1/messages?select=conversation_id,content,role,created_at,kind&order=created_at.desc"
        return await get(url) ?? []
    }

    private func get<T: Decodable>(_ endpoint: String, retrying: Bool = true) async -> T? {
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        let bearer = UserDefaultsManager.shared.accessToken ?? Config.supabaseAnonKey
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return nil }
        // Bir bildirimden SAATLER sonra (ör. Ghosted, 48 saate kadar) uygulama
        // açılırsa erişim token'ı süresi dolmuş olabilir — PostgREST 401 döner,
        // sessizce boş liste döndürmek yerine ChatService.call()'daki aynı
        // desenle bir kere yenile+tekrar dene (bkz. sistematik hata ayıklama:
        // "Chats sekmesi bildirimden sonra boş kalıyor, sadece yeniden başlatma
        // düzeltiyor" raporu — kök neden buydu, diğer sekmeler karakterleri
        // disk önbelleğinden gösterdiği için token'a bağımlı değildi).
        if http.statusCode == 401, retrying {
            _ = await SupabaseAuth.recover()
            return await get(endpoint, retrying: false)
        }
        guard (200..<300).contains(http.statusCode) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
