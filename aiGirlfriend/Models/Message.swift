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
    /// Kullanıcının GÖNDERDİĞİ (botun ürettiği değil) fotoğrafsa, cihazdaki
    /// yerel dosyanın Application Support altındaki göreli yolu (bkz.
    /// UserPhotoStore). `imageURL`'den KASITLI olarak ayrı tutulur — o alan
    /// botun ürettiği/network'ten çekilen fotoğraflara özel (CachedImage/
    /// ImageCache ile), bu ise sadece cihazda, hiç yüklenmez/indirilmez.
    var localImagePath: String?
    /// Doluysa ve `imageURL` hâlâ nil'se: bu bir "ödeme bekleyen" foto isteği
    /// — kullanıcının yazdığı tarif burada saklanır, GERÇEK üretim/token
    /// tahsili SADECE balona dokununca olur (bkz. ChatViewModel.generatePendingImage,
    /// ChatBubble pending-photo dalı). Eski (bu alan gelmeden önce kaydedilmiş)
    /// mesajlarda hep nil — decode güvenli, geriye dönük uyumlu.
    var pendingImagePrompt: String?
    /// true ve `voiceLocalPath` hâlâ nil'se: "ödeme bekleyen" bir sesli mesaj
    /// isteği (bkz. ChatViewModel.generatePendingVoice). Metin tarifi tutmaz —
    /// asıl bot cevabı da dokunulunca üretilir, o anki sohbet geçmişinden gelir.
    var pendingVoiceRequest: Bool?

    init(
        id: UUID = UUID(), role: ChatRole, content: String, createdAt: Date = Date(),
        imageURL: URL? = nil, voiceLocalPath: String? = nil, voiceDuration: Double? = nil,
        localImagePath: String? = nil, pendingImagePrompt: String? = nil, pendingVoiceRequest: Bool? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.imageURL = imageURL
        self.voiceLocalPath = voiceLocalPath
        self.voiceDuration = voiceDuration
        self.localImagePath = localImagePath
        self.pendingImagePrompt = pendingImagePrompt
        self.pendingVoiceRequest = pendingVoiceRequest
    }

    var isUser: Bool { role == .user }
    var isVoice: Bool { voiceLocalPath != nil }
    var isUserPhoto: Bool { localImagePath != nil }
    var isPendingImage: Bool { pendingImagePrompt != nil && imageURL == nil }
    var isPendingVoice: Bool { pendingVoiceRequest == true && voiceLocalPath == nil }
    /// Henüz içeriği/sonucu olmayan bir istek balonu — Grok'a giden wire
    /// history'den HARİÇ tutulmalı (boş içerikli bir tur göndermemek için,
    /// bkz. ChatService wireHistory filtreleri).
    var isPending: Bool { isPendingImage || isPendingVoice }
}
