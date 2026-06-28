//
//  ChatViewModel.swift
//  Sohbet ekranının durumunu yönetir.
//  Geçmiş önbellekten/sunucudan yüklenir; gönderirken sadece yeni mesaj gider.
//

import Foundation
import Observation

@MainActor
@Observable
final class ChatViewModel {
    let character: Character

    var messages: [Message] = []
    var inputText: String = ""
    var isSending: Bool = false
    var isLoadingHistory: Bool = true
    var errorMessage: String?

    // İlişki / XP durumu (kullanıcı+karaktere özel; sunucu hesaplar).
    var relationshipLevel: Int
    var xp: Int = 0
    /// Bir cevapla seviye atlandığında UI bildirimi için (gösterildikten sonra nil yapılır).
    var leveledUpTo: Int?

    var relationshipStage: String { Relationship.stageName(relationshipLevel) }

    private let service = ChatService()

    /// Chat History'de "Yazıyor…" göstermek için paylaşılan durum.
    var store: CharacterStore?
    /// Ekran görünür mü (görünürken gelen cevap okundu sayılır).
    var isVisible = false
    /// İlk mesaj sentetik (açılış selamı, DB'de yok) — sayıma katılmaz.
    private var hasSyntheticOpening = false

    init(character: Character) {
        self.character = character
        self.relationshipLevel = max(1, character.relationshipLevel)
    }

    /// Gösterilen GERÇEK (DB) bot mesajı sayısı (sentetik açılış hariç).
    private var realAssistantCount: Int {
        let c = messages.filter { $0.role == .assistant }.count
        return max(0, c - (hasSyntheticOpening ? 1 : 0))
    }

    /// Şu ana kadar görülen bot mesajlarını okundu işaretle.
    func markReadNow() {
        ReadTracker.setSeen(character.id, realAssistantCount)
    }

    /// Sohbeti temizle (yerel + önbellek). Açılış selamı yeniden gösterilir.
    func clearChat() {
        messages = [Message(role: .assistant, content: openingLine())]
        hasSyntheticOpening = true
        store?.chatCache[character.id] = []
        ReadTracker.setSeen(character.id, 0)
    }

    var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSending && !isLoadingHistory
    }

    /// Ekran açılınca geçmiş sohbeti yükler.
    /// Önbellek (Chat History'de dolduruldu) varsa anında gösterir, yeniden yüklemez.
    func loadHistory() async {
        // 1) Önbellekte varsa anında göster — spinner yok, sunucuya gitme.
        if let cached = store?.chatCache[character.id], !cached.isEmpty {
            messages = cached
            hasSyntheticOpening = false
            isLoadingHistory = false
            markReadNow()
            return
        }
        // 2) Yoksa sunucudan çek.
        isLoadingHistory = true
        errorMessage = nil
        do {
            let history = try await service.loadHistory(character: character)
            relationshipLevel = history.level
            xp = history.xp
            if history.messages.isEmpty {
                messages = [Message(role: .assistant, content: openingLine())]
                hasSyntheticOpening = true
            } else {
                messages = history.messages
                hasSyntheticOpening = false
                store?.chatCache[character.id] = history.messages
            }
        } catch {
            errorMessage = error.localizedDescription
            if messages.isEmpty {
                messages = [Message(role: .assistant, content: openingLine())]
                hasSyntheticOpening = true
            }
        }
        isLoadingHistory = false
        markReadNow()
    }

    /// preset verilirse o metni gönderir (hazır cevaplar), yoksa metin kutusunu.
    func send(_ preset: String? = nil) {
        let text = (preset ?? inputText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, !isLoadingHistory else { return }

        let wantsPhoto = photoRequested(text)
        messages.append(Message(role: .user, content: text))
        updateCache()
        inputText = ""
        isSending = true
        errorMessage = nil
        store?.setTyping(character.id, true)   // Chat History'de "Yazıyor…"

        Task {
            do {
                let result = try await service.send(character: character, userMessage: text)
                messages.append(Message(role: .assistant, content: result.reply))
                // Kullanıcı foto istediyse ve karakterin hazır fotosu varsa, bir foto gönder.
                if wantsPhoto, let photo = character.chatPhotos.randomElement() {
                    messages.append(Message(role: .assistant, content: "", imageURL: photo))
                }
                // İlişki seviyesini güncelle; atladıysa UI'a bildir.
                xp = result.xp
                if result.leveledUp { leveledUpTo = result.level }
                relationshipLevel = result.level
                updateCache()
                // Cevap, kullanıcı sohbeti görüyorsa okundu; değilse okunmamış kalır
                // (Chat History'de "1" rozeti olarak görünür).
                if isVisible { markReadNow() }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSending = false
            store?.setTyping(character.id, false)
        }
    }

    /// Kullanıcının mesajı foto istiyor mu? (basit anahtar kelime tespiti)
    private func photoRequested(_ text: String) -> Bool {
        let t = text.lowercased(with: Locale(identifier: "tr_TR"))
        let keys = ["foto", "fotoğraf", "fotograf", "resim", "selfie", "selfi", "görsel", "gorsel", "pic", "fotonu", "resmini"]
        return keys.contains { t.contains($0) }
    }

    /// Önbelleğe yalnızca gerçek (DB) mesajları yaz — sentetik açılış hariç.
    private func updateCache() {
        let real = hasSyntheticOpening ? Array(messages.dropFirst()) : messages
        if !real.isEmpty { store?.chatCache[character.id] = real }
    }

    private func openingLine() -> String {
        "Selam 👋 Ben \(character.name). Seni özledim, neredeydin?"
    }
}
