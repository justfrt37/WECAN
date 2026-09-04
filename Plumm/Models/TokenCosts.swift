//
//  TokenCosts.swift
//  Display + client-side pre-check ONLY. The server is the source of truth for
//  every actual charge (see each edge function below). A mismatch here is
//  cosmetic; a mismatch in the edge function is real money. Keep in sync:
//
//    message            -> supabase/functions/chat/index.ts             (chargeOrReject(uid, 1, "message"))
//    photo              -> supabase/functions/chat-image/index.ts       (chargeOrReject(uid, 25, "photo"))
//    voiceMessage       -> supabase/functions/voice-message-tts/index.ts (chargeOrReject(uid, 12, "voice"))
//    voiceCallPerMinute -> supabase/functions/voice-call-start/index.ts  (TOKENS_PER_SECOND = 3)
//    characterCreation  -> supabase/functions/create-character/index.ts  (CREATION_COST = 50)
//    levelBoost         -> supabase/functions/level-boost/index.ts       (costForTargetLevel)
//
//  Nicknames are a Pro+/Max entitlement with NO token cost (set-nickname uses
//  requireNicknameEntitlement, never charge_tokens) — not represented here.
//

import Foundation

enum TokenCosts {
    static let message = 1
    static let photo = 25
    static let voiceMessage = 12
    static let voiceCallPerMinute = 180   // 3 tokens/second

    static let characterCreation = 50

    /// Cost to jump to `level` (2...10) via the Boost button. Mirrors
    /// level-boost/index.ts costForTargetLevel exactly.
    static func levelBoost(toLevel level: Int) -> Int {
        if level <= 5 { return 50 }
        if level <= 8 { return 100 }
        return 200
    }
}
