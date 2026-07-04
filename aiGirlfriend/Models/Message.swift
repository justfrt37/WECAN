//
//  Message.swift
//  Tek bir sohbet mesajı.
//

import Foundation

enum ChatRole: String, Codable {
    case user
    case assistant
    case system
}

struct Message: Identifiable, Codable, Hashable {
    let id: UUID
    let role: ChatRole
    var content: String
    let createdAt: Date
    /// Foto mesajıysa görselin URL'i (kızın gönderdiği fotoğraf).
    var imageURL: URL?
    /// Sesli mesajsa, cihazdaki ses dosyasının Application Support altındaki
    /// göreli yolu (bkz. VoicePlayer). Varlığı mesajın "sesli mesaj" olduğunu
    /// gösterir — imageURL'deki idiomun aynısı.
    var voiceLocalPath: String?
    var voiceDuration: Double?

    init(
        id: UUID = UUID(), role: ChatRole, content: String, createdAt: Date = Date(),
        imageURL: URL? = nil, voiceLocalPath: String? = nil, voiceDuration: Double? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.imageURL = imageURL
        self.voiceLocalPath = voiceLocalPath
        self.voiceDuration = voiceDuration
    }

    var isUser: Bool { role == .user }
    var isVoice: Bool { voiceLocalPath != nil }
}
