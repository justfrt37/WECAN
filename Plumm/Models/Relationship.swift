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
            case ..<2:  return String(localized: "Cold")
            case 2:     return String(localized: "Cautious")
            case 3:     return String(localized: "Distant")
            case 4:     return String(localized: "First Step")
            case 5:     return String(localized: "Curious")
            case 6:     return String(localized: "Opening Up")
            case 7:     return String(localized: "Trust")
            case 8:     return String(localized: "Warmth")
            case 9:     return String(localized: "Attachment")
            default:    return String(localized: "Fully Open")
            }
        case "shy":
            switch level {
            case ..<2:  return String(localized: "Scared")
            case 2:     return String(localized: "Timid")
            case 3:     return String(localized: "Shy")
            case 4:     return String(localized: "Nervous")
            case 5:     return String(localized: "Relaxed")
            case 6:     return String(localized: "Trusting")
            case 7:     return String(localized: "Opened Up")
            case 8:     return String(localized: "Warm")
            case 9:     return String(localized: "Deeply In")
            default:    return String(localized: "Sweet Love")
            }
        case "playful":
            switch level {
            case ..<2:  return String(localized: "Playful")
            case 2:     return String(localized: "Witty")
            case 3:     return String(localized: "Banter")
            case 4:     return String(localized: "Teasing")
            case 5:     return String(localized: "Flirty Jokes")
            case 6:     return String(localized: "It's Showing")
            case 7:     return String(localized: "Playful Love")
            case 8:     return String(localized: "Laughs & Kisses")
            case 9:     return String(localized: "Joyful Bond")
            default:    return String(localized: "Joking But Real")
            }
        case "devoted":
            switch level {
            case ..<2:  return String(localized: "Caring")
            case 2:     return String(localized: "Protective")
            case 3:     return String(localized: "Devoted")
            case 4:     return String(localized: "Deep Bond")
            case 5:     return String(localized: "Loyal")
            case 6:     return String(localized: "Obsessive Love")
            case 7:     return String(localized: "Jealousy")
            case 8:     return String(localized: "My Everything")
            case 9:     return String(localized: "Deep Connection")
            default:    return String(localized: "Soulmate")
            }
        case "crazy":
            switch level {
            case ..<2:  return String(localized: "Suspicious")
            case 2:     return String(localized: "Watchful")
            case 3:     return String(localized: "Doubtful")
            case 4:     return String(localized: "Paranoid")
            case 5:     return String(localized: "Controlling")
            case 6:     return String(localized: "Jealousy")
            case 7:     return String(localized: "Drama")
            case 8:     return String(localized: "Emotional Storm")
            case 9:     return String(localized: "Crazy Love")
            default:    return String(localized: "Obsessive")
            }
        case "ex":
            switch level {
            case ..<2:  return String(localized: "Indifferent")
            case 2:     return String(localized: "Cold")
            case 3:     return String(localized: "Sarcastic")
            case 4:     return String(localized: "Cracking")
            case 5:     return String(localized: "In Denial")
            case 6:     return String(localized: "Confession Slip")
            case 7:     return String(localized: "Warming Up")
            case 8:     return String(localized: "Mask Slipping")
            case 9:     return String(localized: "Confession")
            default:    return String(localized: "Back Together")
            }
        default: // flirty
            switch level {
            case ..<2:  return String(localized: "New Meeting")
            case 2:     return String(localized: "Familiar")
            case 3:     return String(localized: "Friends")
            case 4:     return String(localized: "Close Friends")
            case 5:     return String(localized: "Flirting Begins")
            case 6:     return String(localized: "Flirting")
            case 7:     return String(localized: "Potential Partner")
            case 8:     return String(localized: "Partner")
            case 9:     return String(localized: "Serious Relationship")
            default:    return String(localized: "Soulmate")
            }
        }
    }
}
