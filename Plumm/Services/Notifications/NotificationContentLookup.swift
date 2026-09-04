//
//  NotificationContentLookup.swift
//  Shared lookup for the notification dialogue tables (GhostedContent,
//  GoodMorningContent, MissedYouContent, JealousyContent). Each of those files
//  had its own byte-identical copy of this resolution logic, force-unwrapping
//  every level of the nested dictionary. The rules are unchanged: fall back to
//  English when the language is missing, to "flirty" when the role is missing,
//  and to "Sweet" when the vibe is missing.
//

import Foundation

enum NotificationContentLookup {
    private static let fallbackLanguage = "en"
    private static let fallbackRole = "flirty"
    private static let fallbackVibe = "Sweet"

    /// Relationship level → tier key used by the tiered tables.
    static func tier(forLevel level: Int) -> String {
        switch level {
        case ..<4:  return "low"
        case 4..<7: return "mid"
        default:    return "high"
        }
    }

    /// language → role → vibe → lines
    static func line<Value>(
        in table: [String: [String: [String: Value]]],
        language: String,
        role: String,
        vibe: String
    ) -> Value? {
        guard let byRole = table[language] ?? table[fallbackLanguage] else { return nil }
        guard let byVibe = byRole[role] ?? byRole[fallbackRole] else { return nil }
        return byVibe[vibe] ?? byVibe[fallbackVibe]
    }

    /// language → role → vibe → tier → lines. Empty string only if the table
    /// itself is missing an entry, which the shipped tables never are.
    static func randomLine(
        in table: [String: [String: [String: [String: [String]]]]],
        language: String,
        role: String,
        vibe: String,
        level: Int
    ) -> String {
        let byTier = line(in: table, language: language, role: role, vibe: vibe)
        return byTier?[tier(forLevel: level)]?.randomElement() ?? ""
    }

    /// language → role → vibe → lines (no tier axis, see JealousyContent).
    static func randomLine(
        in table: [String: [String: [String: [String]]]],
        language: String,
        role: String,
        vibe: String
    ) -> String {
        line(in: table, language: language, role: role, vibe: vibe)?.randomElement() ?? ""
    }
}
