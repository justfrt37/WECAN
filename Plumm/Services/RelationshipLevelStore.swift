//
//  RelationshipLevelStore.swift
//  Seviye/ilerlemenin KALICI (UserDefaults) küçük önbelleği — sadece iki sayı
//  (level + levelProgress), mesaj YOK.
//
//  NEDEN: sohbet durumunun tek doğru kaynağı sunucu; cihazdaki
//  `LocalConversationStore` yalnızca BELLEK-İÇİ bir önbellek (bkz. o dosyanın
//  başlığı, "SIFIR YEREL"). Bu yüzden uygulama her yeniden açıldığında o
//  önbellek BOŞ başlıyor ve sunucu hidrasyonu gelene kadar sohbet/profil
//  seviyeyi `characters.relationship_level` (eski/global sütun, genelde 1)
//  üzerinden gösterip sonra doğru değere ZIPLIYORDU (bkz. kullanıcı talebi:
//  "seviye geç geliyor, bir yerde sakla").
//
//  Burada tutulan değer bir GÖSTERİM önbelleğidir: ilk karede doğru sayıyı
//  basmak için. Yetki hâlâ sunucuda — hidrasyon/`syncLevelFromServer` gelince
//  değer üzerine yazılır (bkz. CharacterStore.setLevel, buradan da yazılır).
//
//  İsim uzayı kullanıcıya göre (anonim kullanıcı değişirse başkasının seviyesi
//  sızmasın) — LocalConversationStore'un `userKey()` deseniyle aynı.
//

import Foundation

enum RelationshipLevelStore {
    private static let defaults = UserDefaults.standard

    private static func key() -> String {
        "relationship.levels.v1.\(UserDefaultsManager.shared.userId ?? "anonymous")"
    }

    /// characterID.uuidString → ["l": level, "p": progress]
    private static var table: [String: [String: Double]] {
        get { defaults.dictionary(forKey: key()) as? [String: [String: Double]] ?? [:] }
        set { defaults.set(newValue, forKey: key()) }
    }

    static func level(for characterID: UUID) -> (level: Int, progress: Double)? {
        guard let row = table[characterID.uuidString], let l = row["l"] else { return nil }
        return (level: max(1, Int(l)), progress: row["p"] ?? 0)
    }

    /// Bilinen seviyeyi yazar. Aynı değerse diske hiç dokunmaz (her mesajda
    /// çağrıldığı için gereksiz yazma olmasın).
    static func set(_ characterID: UUID, level: Int, progress: Double) {
        let id = characterID.uuidString
        var t = table
        if let existing = t[id], Int(existing["l"] ?? 0) == level, existing["p"] == progress { return }
        t[id] = ["l": Double(level), "p": progress]
        table = t
    }

    /// Sohbet silinince/sıfırlanınca kaydı da sil (bkz. LocalConversationStore.clear).
    static func remove(_ characterID: UUID) {
        var t = table
        guard t.removeValue(forKey: characterID.uuidString) != nil else { return }
        table = t
    }

    static func removeAll() {
        defaults.removeObject(forKey: key())
    }
}
