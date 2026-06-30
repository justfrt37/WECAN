//
//  Relationship.swift
//  İlişki seviyesi (1-10) ↔ aşama adı eşlemesi.
//  Seviye sunucuda hesaplanır (chat Edge Function); burada yalnızca gösterim için
//  aşama adını çözeriz. Sunucudaki intimacyDirective ile aynı isimlendirme.
//

import Foundation

enum Relationship {
    static let maxLevel = 10

    /// Role-aware stage name. Each role has its own progression labels.
    static func stageName(_ level: Int, role: String = "flirty") -> String {
        switch role {
        case "distant":
            switch level {
            case ..<2:  return "Soğuk"
            case 2:     return "Temkinli"
            case 3:     return "Mesafeli"
            case 4:     return "İlk Adım"
            case 5:     return "Merak"
            case 6:     return "Açılıyor"
            case 7:     return "Güven"
            case 8:     return "Sıcaklık"
            case 9:     return "Bağlılık"
            default:    return "Tam Açık"
            }
        case "shy":
            switch level {
            case ..<2:  return "Korkuyor"
            case 2:     return "Çekingen"
            case 3:     return "Utangaç"
            case 4:     return "Tedirgin"
            case 5:     return "Rahatladı"
            case 6:     return "Güvendi"
            case 7:     return "Açıldı"
            case 8:     return "Sıcakkanlı"
            case 9:     return "Derinden"
            default:    return "Tatlı Aşk"
            }
        case "playful":
            switch level {
            case ..<2:  return "Şakacı"
            case 2:     return "Esprili"
            case 3:     return "Çekişme"
            case 4:     return "Takılma"
            case 5:     return "Flörtöz Şaka"
            case 6:     return "Belli Oluyor"
            case 7:     return "Oyuncu Aşk"
            case 8:     return "Kahkaha & Öpücük"
            case 9:     return "Neşeli Bağ"
            default:    return "Şakayla Gerçek"
            }
        case "devoted":
            switch level {
            case ..<2:  return "Özenli"
            case 2:     return "Koruyucu"
            case 3:     return "Adanmış"
            case 4:     return "Yoğun Bağ"
            case 5:     return "Sadık"
            case 6:     return "Takıntılı Sevgi"
            case 7:     return "Kıskançlık"
            case 8:     return "Her Şeyim"
            case 9:     return "Derin Bağ"
            default:    return "Ruh Eşi"
            }
        case "crazy":
            switch level {
            case ..<2:  return "Kuşkulu"
            case 2:     return "Gözlemci"
            case 3:     return "Şüpheci"
            case 4:     return "Paranoid"
            case 5:     return "Kontrol Ediyor"
            case 6:     return "Kıskançlık"
            case 7:     return "Drama"
            case 8:     return "Duygusal Fırtına"
            case 9:     return "Çılgın Aşk"
            default:    return "Takıntılı"
            }
        case "ex":
            switch level {
            case ..<2:  return "Kayıtsız"
            case 2:     return "Soğuk"
            case 3:     return "Alaycı"
            case 4:     return "Çatlak Var"
            case 5:     return "Kabul Etmiyor"
            case 6:     return "İtiraf Kırıntısı"
            case 7:     return "Isınıyor"
            case 8:     return "Maske Düşüyor"
            case 9:     return "İtiraf"
            default:    return "Geri Döndü"
            }
        default: // flirty
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
}
