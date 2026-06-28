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

    init(id: UUID = UUID(), role: ChatRole, content: String, createdAt: Date = Date(), imageURL: URL? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.imageURL = imageURL
    }

    var isUser: Bool { role == .user }
}
