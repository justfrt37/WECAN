//
//  Relationship.swift
//  İlişki seviyesi (1-10) ↔ aşama adı eşlemesi.
//  Seviye sunucuda hesaplanır (chat Edge Function); burada yalnızca gösterim için
//  aşama adını çözeriz. Sunucudaki intimacyDirective ile aynı isimlendirme.
//

import Foundation

enum Relationship {
    static let maxLevel = 10

    /// Seviyeye karşılık gelen ilişki aşaması (gösterim adı).
    static func stageName(_ level: Int) -> String {
        switch level {
        case ..<2:  return "Yeni Tanışma"
        case 2:     return "Tanıdık"
        case 3:     return "Arkadaş"
        case 4:     return "Yakın Arkadaş"
        case 5:     return "Flört Başlangıcı"
        case 6:     return "Flört"
        case 7:     return "Sevgili Adayı"
        case 8:     return "Sevgili"
        case 9:     return "Ciddi İlişki"
        default:    return "Ruh Eşi"
        }
    }
}
