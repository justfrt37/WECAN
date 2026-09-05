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
    /// Reload'da sunucudan gelen sesli mesajın Storage URL'i (kind == "voice").
    /// `voiceLocalPath` cihazda yoksa ses buradan indirilip çalınır — foto'daki
    /// `imageURL` idiomunun ses karşılığı.
    var voiceRemoteURL: URL?
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
    /// Bu pending ses balonunu SUNUCUDA oluştururken kullanılan `requestText`
    /// (kind=voice_pending satırının `content`'i). Üretim bitince sunucudaki
    /// pending satırını gerçek sese çevirmek AYNI metinle eşleştirmeye dayanır
    /// (bkz. chat/index.ts voiceMessage). Düğme akışında bu = kullanıcının
    /// eklediği metin, otomatik ([[SEND_VOICE]]) akışta ise sabit "Send me a
    /// voice" — ikisi generatePendingVoice'ın hesapladığı "önceki kullanıcı
    /// mesajı"ndan farklı olabilir, bu yüzden ayrıca saklanır (yoksa eşleşme
    /// tutmaz, sunucu yeni bir `voice` satırı ekler → yinelenen balon + öksüz
    /// kilitli balon hatası). Eski kayıtlarda/rows'ta nil.
    var pendingVoiceRequestText: String?
    /// true ise bu mesajın gönderimi başarısız oldu (ağ hatası vb., 402 hariç —
    /// bkz. ChatViewModel.isInsufficientTokensError) — balon üzerinde bir hata
    /// göstergesi gösterilir, dokununca yeniden denenir (bkz. ChatViewModel.retrySend).
    var failed: Bool?
    /// Kullanıcının bota gönderdiği fotoğraf 7 gün sonra süpürülüp (bkz.
    /// sweepExpiredUserPhotos, migration 020_user_sent_photos.sql) yerine
    /// bu bayrak geldiyse true — balonda "Photo expired" yer tutucusu gösterilir.
    var isExpiredUserPhoto: Bool?

    init(
        id: UUID = UUID(), role: ChatRole, content: String, createdAt: Date = Date(),
        imageURL: URL? = nil, voiceLocalPath: String? = nil, voiceDuration: Double? = nil,
        voiceRemoteURL: URL? = nil,
        localImagePath: String? = nil, pendingImagePrompt: String? = nil, pendingVoiceRequest: Bool? = nil,
        pendingVoiceRequestText: String? = nil,
        failed: Bool? = nil, isExpiredUserPhoto: Bool? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.imageURL = imageURL
        self.voiceLocalPath = voiceLocalPath
        self.voiceDuration = voiceDuration
        self.voiceRemoteURL = voiceRemoteURL
        self.localImagePath = localImagePath
        self.pendingImagePrompt = pendingImagePrompt
        self.pendingVoiceRequest = pendingVoiceRequest
        self.pendingVoiceRequestText = pendingVoiceRequestText
        self.failed = failed
        self.isExpiredUserPhoto = isExpiredUserPhoto
    }

    /// Sunucudan gelen bir satırdan (role/content/kind) görüntülenebilir Message
    /// kurar. `kind == "image"` → üretilmiş fotoğraf (sunucu-barındırmalı URL,
    /// content = URL) `imageURL`'e döner; böylece sohbete tekrar girince foto
    /// yeniden görünür (bkz. "resimler görünmüyor" hatası). Ses (`voice`)
    /// cihazda saklandığından reload'da geri gelmez, metin gibi düşer.
    static func fromServer(role: String, content: String, kind: String?, createdAt: Date) -> Message {
        let r = ChatRole(rawValue: role) ?? .assistant
        if kind == "image", let url = URL(string: content) {
            return Message(role: r, content: "", createdAt: createdAt, imageURL: url)
        }
        // "Açılmamış/kilitli" foto — kullanıcı isteği attı ama henüz üretmedi.
        // Reload'da yine "üret" (pending) balonu olarak görünür; content = üretim
        // prompt'u (bkz. chat/index.ts photoMessage, "açılmamış foto tutulmalı").
        if kind == "image_pending" {
            return Message(role: r, content: "", createdAt: createdAt, pendingImagePrompt: content)
        }
        // Üretilmiş sesli mesaj (content = Storage URL) → reload'da yine SES balonu
        // olarak görünür, metin değil (bkz. kullanıcı talebi). Ses buradan indirilir.
        if kind == "voice", let url = URL(string: content) {
            return Message(role: r, content: "", createdAt: createdAt, voiceRemoteURL: url)
        }
        // "Açılmamış/kilitli" ses isteği — reload'da yine pending (kilitli) balon.
        if kind == "voice_pending" {
            // `content` = pending satırı oluşturulurken kullanılan requestText —
            // üretim bitince sunucudaki eşleştirme bununla yapılır, bu yüzden
            // balonda saklanır (bkz. pendingVoiceRequestText).
            return Message(role: r, content: "", createdAt: createdAt,
                           pendingVoiceRequest: true, pendingVoiceRequestText: content)
        }
        // Kullanıcının bota gönderdiği, sunucuda KALICI hale getirilmiş fotoğraf
        // (bkz. chat/index.ts persistUserPhoto) — content = imzalı Storage URL,
        // her history isteğinde taze üretilir. `role` zaten "user" olduğundan
        // botun kendi ürettiği `kind == "image"` (role "assistant") ile
        // karışmaz, aynı `imageURL` alanı + bubble'ı güvenle paylaşılır.
        if kind == "user_photo", let url = URL(string: content) {
            return Message(role: r, content: "", createdAt: createdAt, imageURL: url)
        }
        // 7 gün dolup süpürülmüş — yer tutucu balon (bkz. sweepExpiredUserPhotos).
        if kind == "user_photo_expired" {
            return Message(role: r, content: "", createdAt: createdAt, isExpiredUserPhoto: true)
        }
        return Message(role: r, content: content, createdAt: createdAt)
    }

    var isUser: Bool { role == .user }
    var isVoice: Bool { voiceLocalPath != nil || voiceRemoteURL != nil }
    var isUserPhoto: Bool { localImagePath != nil || (imageURL != nil && role == .user) }
    var isPendingImage: Bool { pendingImagePrompt != nil && imageURL == nil }
    var isPendingVoice: Bool { pendingVoiceRequest == true && voiceLocalPath == nil && voiceRemoteURL == nil }
    /// Henüz içeriği/sonucu olmayan bir istek balonu — Grok'a giden wire
    /// history'den HARİÇ tutulmalı (boş içerikli bir tur göndermemek için,
    /// bkz. ChatService wireHistory filtreleri).
    var isPending: Bool { isPendingImage || isPendingVoice }
}
