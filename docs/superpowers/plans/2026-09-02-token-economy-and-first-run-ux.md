# Token Economy Visibility, Relationship-Level Rework & First-Run Feature Tour — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the broken token-for-level boost, make the relationship-level screen discoverable with role-aware non-romantic names, surface per-feature token costs to users, and add a TipKit first-run feature tour.

**Architecture:** Five loosely-coupled changes on `furkan_dev`. One server migration (deploy-gated on Supabase returning). The rest is client SwiftUI: a display-only `TokenCosts` constants file, a `TokenCostsView` list screen, a rewrite of `RelationshipLevelsView` to drive off the existing `Relationship.stageName`, a `RELATIONSHIP` section in `CharacterProfileView`, and a TipKit tip set gated behind onboarding completion.

**Tech Stack:** Swift 5 / SwiftUI, iOS 17.0 target, Apple TipKit, Supabase (Postgres migration, Deno edge functions — not modified here), `npx supabase` CLI.

**Spec:** `docs/superpowers/specs/2026-09-02-token-economy-and-first-run-ux-design.md`

## Global Constraints

- Branch: `furkan_dev`. Do not branch off; commit directly here (per user instruction 2026-09-02).
- **No XCTest target exists in this repo.** The per-task "test cycle" is: (a) `xcodebuild -scheme Plumm -destination 'platform=iOS Simulator,name=iPhone 16' build` succeeds with no new warnings in touched files, and (b) the explicit manual simulator checks listed in the task. Do not add a test target (user declined 2026-09-02).
- Server is the single source of truth for token charging and balances. `TokenCosts.swift` is display + client-precheck only.
- Deployment floor iOS 17.0 — TipKit `Tips.configure`, `popoverTip`, `Tips.Event`, `Tips.resetDatastore` are all 17.0+, no `#available` fences needed.
- Level names must not use marriage / engagement / civil-status words (`Lovers`, `Engaged`, `Committed`, `Married`, `Fiancé`). Emotional-closeness words are fine.
- All new user-facing strings use `String(localized:)`, matching the codebase.
- Analytics: `EventLogger.shared.log("feature_used", ["feature": "..."])` — no new event names unless noted.
- Supabase is down until ~2026-09-02 evening. Task 1's migration is committed now, applied when Supabase returns; every other task is unblocked.

---

## Task 1: Fix the level-boost reason allowlist (server)

**Files:**
- Create: `supabase/migrations/028_level_boost_reason.sql`

**Interfaces:**
- Consumes: nothing.
- Produces: `token_transactions.reason` accepts `'level_boost'`; unblocks `level-boost/index.ts` which is already correct.

- [ ] **Step 1: Write the migration**

`supabase/migrations/028_level_boost_reason.sql`:

```sql
-- supabase/migrations/028_level_boost_reason.sql
--
-- level-boost/index.ts charges tokens with p_reason: "level_boost", which was
-- never added to token_transactions_reason_check. charge_tokens() therefore
-- raises a check-constraint violation on the ledger insert, the whole plpgsql
-- function rolls back, the RPC returns null, and the edge function reports a
-- false "insufficient_tokens" (402) regardless of the user's real balance or
-- subscription tier. Identical failure mode to migration 025 (character_creation).
-- Confirmed 2026-09-02: a Pro Max account with ~7k tokens could not boost.

alter table token_transactions drop constraint token_transactions_reason_check;
alter table token_transactions add constraint token_transactions_reason_check
  check (reason in ('message', 'voice', 'photo', 'streak', 'purchase',
                    'subscription_grant', 'welcome', 'debug', 'character_creation',
                    'level_boost'));
```

- [ ] **Step 2: Verify no other reason string is outside the allowlist**

Run:
```bash
grep -rn "p_reason:" supabase/functions/ | grep -v node_modules
```
Expected: reasons are exactly `message`, `voice`, `photo`, `character_creation`, `subscription_grant`, `purchase`, `level_boost` — every one except `level_boost` already in the constraint, and `level_boost` now added. If a new one appears, add it to the migration too.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/028_level_boost_reason.sql
git commit -m "fix(tokens): allow 'level_boost' in token_transactions reason check

level-boost charged with an un-allowlisted reason, so charge_tokens rolled
back and every boost returned a false insufficient_tokens (402). Same class
as migration 025.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

- [ ] **Step 4: Apply when Supabase is back (deferred)**

Run (needs `SUPABASE_ACCESS_TOKEN`, see `docs/context/supabase_access.md`):
```bash
npx supabase db push --project-ref ohpvhgwjmrfjclnumgnm
```
Then manual check with a funded account: boost L1→L2 succeeds, balance drops by `TokenCosts.levelBoost(toLevel: 2)` (50), a `token_transactions` row with `reason='level_boost'` exists, no token-store redirect.

---

## Task 2: `TokenCosts` display-source model

**Files:**
- Create: `Plumm/Models/TokenCosts.swift`

**Interfaces:**
- Produces:
  - `enum TokenCosts`
  - `TokenCosts.message: Int` (1), `.photo: Int` (25), `.voiceMessage: Int` (12), `.voiceCallPerMinute: Int` (180), `.characterCreation: Int` (50)
  - `TokenCosts.levelBoost(toLevel: Int) -> Int` (50 / 100 / 200)

- [ ] **Step 1: Write the file**

`Plumm/Models/TokenCosts.swift`:

```swift
//
//  TokenCosts.swift
//  Display + client-side pre-check ONLY. The server is the source of truth for
//  every actual charge (see each edge function below). A mismatch here is
//  cosmetic; a mismatch in the edge function is real money. Keep in sync:
//
//    message            -> supabase/functions/chat/index.ts        (chargeOrReject(uid, 1, "message"))
//    photo              -> supabase/functions/chat-image/index.ts  (chargeOrReject(uid, 25, "photo"))
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
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme Plumm -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add Plumm/Models/TokenCosts.swift
git commit -m "feat(tokens): add TokenCosts display-source constants"
```

---

## Task 3: Replace scattered cost literals with `TokenCosts`

**Files:**
- Modify: `Plumm/Views/RelationshipLevelsView.swift` (the `boostCost(forTargetLevel:)` helper, ~lines 60-64)
- Grep-and-check: `Plumm/Views/ChatView.swift`, `Plumm/ViewModels/ChatViewModel.swift` for hardcoded `25` / `12` / `50` token literals in cost labels

**Interfaces:**
- Consumes: `TokenCosts` (Task 2).

- [ ] **Step 1: Find every client-side cost literal**

Run:
```bash
grep -rn "🪙\|token" Plumm/Views/*.swift Plumm/ViewModels/*.swift | grep -iE "cost|[^0-9](12|25|50|100|200)[^0-9]"
```
Note each hardcoded cost. Expected hits: `RelationshipLevelsView.boostCost`, possibly a photo/voice sub-label in `ChatView`.

- [ ] **Step 2: Replace in `RelationshipLevelsView`**

Delete the private `boostCost(forTargetLevel:)` method. Replace its two call sites (`boost()` and `boostButton`) with `TokenCosts.levelBoost(toLevel: targetLevel)` / `TokenCosts.levelBoost(toLevel: currentLevel + 1)`.

- [ ] **Step 3: Replace any ChatView photo/voice cost labels**

Wherever a paid-action button in `ChatView` shows a number, use `TokenCosts.photo` / `TokenCosts.voiceMessage`. If none exist yet, add a `"\(TokenCosts.photo) 🪙"` caption under the photo button and `"\(TokenCosts.voiceMessage) 🪙"` under the voice button, matching the existing boost button's sub-label style (`.font(.system(size: 10, weight: .semibold))`).

- [ ] **Step 4: Build + manual check**

Run the build. Then in the simulator: open a chat, confirm the photo and voice buttons show their token cost; open a character profile → levels sheet, confirm the boost button still shows `50` at low levels.

- [ ] **Step 5: Commit**

```bash
git add Plumm/Views/RelationshipLevelsView.swift Plumm/Views/ChatView.swift
git commit -m "refactor(tokens): source client cost labels from TokenCosts"
```

---

## Task 4: `TokenCostsView` screen + entry points

**Files:**
- Create: `Plumm/Views/TokenCostsView.swift`
- Modify: `Plumm/Views/TokenStoreView.swift` (header, ~lines 140-169: add an info button)
- Modify: `Plumm/Views/ProfileView.swift` (add a "Token costs" row in the existing settings list)

**Interfaces:**
- Consumes: `TokenCosts` (Task 2).
- Produces: `TokenCostsView` (a `View`, no required init args).

- [ ] **Step 1: Write `TokenCostsView`**

`Plumm/Views/TokenCostsView.swift`:

```swift
//
//  TokenCostsView.swift
//  "What do tokens buy?" — a plain reference list. Values are display-only
//  (see TokenCosts.swift); the server always decides the real charge.
//  Reached from TokenStoreView (info button) and ProfileView (settings row).
//

import SwiftUI

struct TokenCostsView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable {
        let id = UUID()
        let name: String
        let cost: String
    }

    private let rows: [Row] = [
        .init(name: String(localized: "Send a message"),        cost: "\(TokenCosts.message)"),
        .init(name: String(localized: "Ask for a photo"),       cost: "\(TokenCosts.photo)"),
        .init(name: String(localized: "Send a voice message"),  cost: "\(TokenCosts.voiceMessage)"),
        .init(name: String(localized: "Voice call"),            cost: String(localized: "\(TokenCosts.voiceCallPerMinute) / min")),
        .init(name: String(localized: "Create a character"),    cost: "\(TokenCosts.characterCreation)"),
        .init(name: String(localized: "Boost a relationship level"), cost: String(localized: "50–200")),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(rows) { row in
                        HStack {
                            Text(row.name)
                            Spacer()
                            HStack(spacing: 4) {
                                Text(row.cost).monospacedDigit().fontWeight(.semibold)
                                CoinIcon(size: 13)
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Nicknames are included with Pro+. Earn tokens with your daily streak or top up in the Store.")
                }
            }
            .navigationTitle("Token Costs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview { TokenCostsView() }
```

(If `CoinIcon` is not the right symbol name, check `Plumm/Views/TokenBadge.swift` / `TokenStoreView.swift` for the existing coin glyph type and use that.)

- [ ] **Step 2: Add the info button to `TokenStoreView` header**

In `TokenStoreView`, add `@State private var showCosts = false`. In the `header` `HStack`, between the back button and `Spacer()`, add:

```swift
Button { showCosts = true } label: {
    Image(systemName: "info.circle")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white.opacity(0.85))
        .frame(width: 40, height: 40)
        .background(.white.opacity(0.10), in: Circle())
}
.buttonStyle(.plain)
```

Add to the view: `.sheet(isPresented: $showCosts) { TokenCostsView() }`.

- [ ] **Step 3: Add the `ProfileView` row**

In `ProfileView`, in the existing settings `List`/section (find the section holding rows like "Notifications" / "Help & Support"), add:

```swift
NavigationLink { TokenCostsView() } label: {
    Label("Token costs", systemImage: "dollarsign.circle")
}
```

Match whatever row style the surrounding code uses (it may be a custom row builder rather than `Label` — follow the local pattern).

- [ ] **Step 4: Build + manual check**

Build. In the simulator: Settings tab → "Token costs" opens the list. Chat header → token badge → Store → info button → same list. Values read 1 / 25 / 12 / 180 / min / 50 / 50–200.

- [ ] **Step 5: Commit**

```bash
git add Plumm/Views/TokenCostsView.swift Plumm/Views/TokenStoreView.swift Plumm/Views/ProfileView.swift
git commit -m "feat(tokens): add Token Costs reference screen with Store + Settings entry points"
```

---

## Task 5: `Relationship` — non-romantic names + blurbs

**Files:**
- Modify: `Plumm/Models/Relationship.swift`

**Interfaces:**
- Produces:
  - `Relationship.stageName(_ level: Int, role: String = "flirty") -> String` (signature unchanged; some return strings revised)
  - `Relationship.stageBlurb(_ level: Int) -> String` (new; role-agnostic; covers 1...10 and `<1`)

- [ ] **Step 1: Confirm the copy with the user before editing**

The revised `stageName` strings and the new blurbs below are **proposed copy**. Post them in chat and get a yes/adjust before touching the file. Proposed `stageName` changes (only the civil-status-flavored entries change; everything else stays):

| role | level | current | proposed |
|---|---|---|---|
| flirty | 7 | Potential Partner | Something More |
| flirty | 8 | Partner | Inseparable |
| flirty | 9 | Serious Relationship | Deeply Bonded |
| flirty | 10 | Soulmate | Soulmate *(keep)* |
| devoted | 6 | Obsessive Love | Devotion Deepens |
| devoted | 8 | My Everything | Fiercely Attached |
| crazy | 9 | Crazy Love | Consumed |
| ex | 10 | Back Together | Reconciled |
| shy | 10 | Sweet Love | Wholehearted |
| playful | 7 | Playful Love | Smitten |

Proposed blurbs (role-agnostic):

| level | blurb |
|---|---|
| 1 | You've just met. Everything's still first impressions. |
| 2 | The awkwardness is fading. You're finding a rhythm. |
| 3 | There's real familiarity now — you look forward to talking. |
| 4 | You trust each other with the everyday stuff. |
| 5 | The tone is shifting. Something warmer is starting to show. |
| 6 | You're openly close, and it colors how you talk. |
| 7 | You let each other in past the surface. |
| 8 | You share things you don't tell anyone else. |
| 9 | You've become a fixed point for each other. |
| 10 | About as close as two people get. |

- [ ] **Step 2: Apply the approved `stageName` edits**

Edit the specific `case` return strings in `Relationship.stageName` per the approved table. Leave `role` defaulting to `"flirty"`. Do not restructure the switch.

- [ ] **Step 3: Add `stageBlurb`**

Append to `enum Relationship`:

```swift
/// Role-agnostic one-liner describing how deep the bond is at `level`.
/// The role supplies the flavor via `stageName`; this stays neutral.
static func stageBlurb(_ level: Int) -> String {
    switch level {
    case ..<2:  return String(localized: "You've just met. Everything's still first impressions.")
    case 2:     return String(localized: "The awkwardness is fading. You're finding a rhythm.")
    case 3:     return String(localized: "There's real familiarity now — you look forward to talking.")
    case 4:     return String(localized: "You trust each other with the everyday stuff.")
    case 5:     return String(localized: "The tone is shifting. Something warmer is starting to show.")
    case 6:     return String(localized: "You're openly close, and it colors how you talk.")
    case 7:     return String(localized: "You let each other in past the surface.")
    case 8:     return String(localized: "You share things you don't tell anyone else.")
    case 9:     return String(localized: "You've become a fixed point for each other.")
    default:    return String(localized: "About as close as two people get.")
    }
}
```

- [ ] **Step 4: Build + manual check**

Build. In the simulator, level up a `flirty` character in chat and confirm the level-up avatar pulse still works and any stage text shown reads the new copy. (Full display verification happens in Task 6.)

- [ ] **Step 5: Commit**

```bash
git add Plumm/Models/Relationship.swift
git commit -m "feat(relationship): de-romanticize stage names, add role-agnostic blurbs"
```

---

## Task 6: `RelationshipLevelsView` — drive off `stageName`, add role param, explain boosting

**Files:**
- Modify: `Plumm/Views/RelationshipLevelsView.swift`

**Interfaces:**
- Consumes: `Relationship.stageName`, `Relationship.stageBlurb` (Task 5); `TokenCosts.levelBoost` (Task 3); the new `BoostOutcome` is Task 8 — **for now keep the existing `boostLevel() -> LevelBoostResult?` call**; Task 8 rewires the failure branch.
- Produces: `RelationshipLevelsView(characterId:role:currentLevel:tokenBalance:onBoosted:onInsufficientTokens:)` — new required `role: String` parameter.

- [ ] **Step 1: Delete the hardcoded ladder**

Remove `private struct RelationshipLevel` and the `private let relationshipLevels: [RelationshipLevel]` array (lines ~11-29).

- [ ] **Step 2: Add `role`, regenerate rows from the model**

- Add `let role: String` stored property and thread it through `init`.
- Replace `ForEach(relationshipLevels) { level in levelRow(level) }` with `ForEach(1...Self.maxLevel, id: \.self) { lvl in levelRow(lvl) }`.
- Rewrite `levelRow(_ level: RelationshipLevel)` as `levelRow(_ level: Int)`:
  - title → `Relationship.stageName(level, role: role)`
  - blurb → `Relationship.stageBlurb(level)`
  - `isCurrent` → `level == currentLevel`; `isPast` → `level < currentLevel`; `isTop` → `level == Self.maxLevel`
  - the boost button still renders only on `level == currentLevel + 1`

- [ ] **Step 3: Add the explanatory header line**

In `header`, below the existing subtitle, when `currentLevel < Self.maxLevel`:

```swift
Text("Chat to grow closer over time — or spend tokens to jump ahead now.")
    .font(.system(size: 13, weight: .medium))
    .foregroundStyle(.white.opacity(0.65))
```

- [ ] **Step 4: Update the `#Preview` and the `CharacterProfileView` call site**

- `#Preview`: add `role: "flirty"`.
- `CharacterProfileView` `showLevels` sheet: add `role: character.personalityRole`. (Full profile changes are Task 7; this is the minimal compile fix.)

- [ ] **Step 5: Build + manual check**

Build. Simulator: open a `crazy` character's profile → levels sheet shows `Suspicious … Consumed … Obsessive`; open a `shy` character → `Scared … Wholehearted`. Boost button shows on the next level only, at the right cost. Header shows the new "jump ahead" line.

- [ ] **Step 6: Commit**

```bash
git add Plumm/Views/RelationshipLevelsView.swift Plumm/Views/CharacterProfileView.swift
git commit -m "feat(relationship): role-aware level screen, remove hardcoded romantic ladder"
```

---

## Task 7: `CharacterProfileView` — discoverable RELATIONSHIP section

**Files:**
- Modify: `Plumm/Views/CharacterProfileView.swift`

**Interfaces:**
- Consumes: `Relationship.stageName`, `userLevel`, `userLevelProgress` (existing computed props).
- Produces: a `relationshipSection` view; `showLevels` now reachable from the body, not only the hero circle.

- [ ] **Step 1: Add the section view**

Add near `about`:

```swift
private var relationshipSection: some View {
    VStack(alignment: .leading, spacing: 10) {
        Text("RELATIONSHIP")
            .font(.system(size: 13, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(.white.opacity(0.8))
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Level \(userLevel) · \(Relationship.stageName(userLevel, role: character.personalityRole))")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                ProgressView(value: userLevelProgress)
                    .tint(AppColor.pink)
                    .frame(maxWidth: 180)
            }
            Spacer()
            Button {
                showLevels = true
                EventLogger.shared.log("feature_used", [
                    "feature": "relationship_levels_opened", "source": "profile_section",
                ])
            } label: {
                Text("View progress")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(AppColor.pink.opacity(0.9), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}
```

- [ ] **Step 2: Place it in the scroll body**

In `body`'s `VStack`, insert `relationshipSection` right after `about`, with `.padding(.horizontal, 24).padding(.top, 22)` to match siblings.

- [ ] **Step 3: Caption under the hero circle**

In `levelCircle`, wrap the `Button` in a `VStack(spacing: 4)` and add below it:

```swift
Text("Tap for levels")
    .font(.system(size: 10, weight: .medium))
    .foregroundStyle(.white.opacity(0.6))
```

Tag the hero-circle open with source `"hero_circle"` in an `EventLogger` call inside that button's action (it currently just sets `showLevels = true`).

- [ ] **Step 4: Build + manual check**

Build. Simulator: open any character profile → a RELATIONSHIP row is visible without scrolling into the hero; "View progress" opens the sheet; the hero circle now reads "Tap for levels" and also opens it.

- [ ] **Step 5: Commit**

```bash
git add Plumm/Views/CharacterProfileView.swift
git commit -m "feat(relationship): add discoverable RELATIONSHIP section to character profile"
```

---

## Task 8: Typed boost failure — stop the false store redirect

**Files:**
- Modify: `Plumm/Services/ChatService.swift` (the `boostLevel` method + its `LevelBoostResponse` / `LevelBoostResult` types, ~lines 295-335)
- Modify: `Plumm/Views/RelationshipLevelsView.swift` (`boost()` + a new inline error state)

**Interfaces:**
- Produces:
  - `enum ChatService.BoostOutcome { case success(LevelBoostResult); case insufficientTokens; case alreadyMaxLevel; case failed }`
  - `ChatService.boostLevel(characterId: UUID) async -> BoostOutcome` (return type changed from `LevelBoostResult?`)

- [ ] **Step 1: Rewrite `boostLevel` to read the status code + error body**

```swift
enum BoostOutcome {
    case success(LevelBoostResult)
    case insufficientTokens
    case alreadyMaxLevel
    case failed
}

func boostLevel(characterId: UUID) async -> BoostOutcome {
    var request = authorizedRequest(url: Config.levelBoostFunctionURL, timeout: 20)
    request.httpBody = try? JSONEncoder().encode(LevelBoostRequest(characterId: characterId.uuidString.lowercased()))

    guard let (data, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse
    else { return .failed }

    if (200..<300).contains(http.statusCode) {
        guard let decoded = try? JSONDecoder().decode(LevelBoostResponse.self, from: data),
              let level = decoded.level, let progress = decoded.levelProgress, let balance = decoded.tokenBalance
        else { return .failed }
        return .success(LevelBoostResult(level: level, levelProgress: progress, tokenBalance: balance))
    }

    let errorCode = (try? JSONDecoder().decode(LevelBoostErrorBody.self, from: data))?.error
    switch (http.statusCode, errorCode) {
    case (402, _):                       return .insufficientTokens
    case (400, "already_max_level"):     return .alreadyMaxLevel
    default:                             return .failed
    }
}

private struct LevelBoostErrorBody: Decodable { let error: String? }
```

- [ ] **Step 2: Handle the outcomes in `RelationshipLevelsView.boost()`**

Add `@State private var boostError: String?`. Rewrite the `Task` body:

```swift
switch await service.boostLevel(characterId: characterId) {
case .success(let result):
    currentLevel = result.level
    tokenBalance = result.tokenBalance
    EventLogger.shared.log("feature_used", ["feature": "level_boost", "new_level": result.level])
    onBoosted(result.level, result.tokenBalance)
case .insufficientTokens:
    onInsufficientTokens()
case .alreadyMaxLevel:
    currentLevel = Self.maxLevel
case .failed:
    boostError = String(localized: "Couldn't boost right now. Check your connection and try again.")
}
isBoosting = false
```

- [ ] **Step 3: Show the inline error**

Add `.alert("", isPresented: .constant(boostError != nil)) { Button("OK") { boostError = nil } } message: { Text(boostError ?? "") }` (or a small inline banner matching the file's style).

- [ ] **Step 4: Build + manual check**

Build. Simulator with **airplane mode on**: tap Boost → "Couldn't boost right now…" alert, **no** token-store redirect. (Happy path and real 402 require Supabase — verify post-deploy per Task 1 Step 4.)

- [ ] **Step 5: Commit**

```bash
git add Plumm/Services/ChatService.swift Plumm/Views/RelationshipLevelsView.swift
git commit -m "fix(relationship): typed boost outcome, stop routing network errors to token store"
```

---

## Task 9: TipKit tip set + onboarding-gated configuration

**Files:**
- Create: `Plumm/Services/Tips/PlummTips.swift`
- Modify: `Plumm/PlummApp.swift` (add `Tips.configure` in the existing launch `.task`, ~lines 60-75)

**Interfaces:**
- Produces:
  - `enum PlummTips` with `static func configureIfEligible(onboardingCompleted: Bool)`
  - Tip types: `SendFirstMessageTip`, `RequestPhotoTip`, `VoiceMessageTip`, `VoiceCallTip`, `TokenBadgeTip`, `LevelSectionTip`, `CreateCharacterTip`
  - `static` `Tips.Event` donations: `PlummTips.chatOpened`, `.messageSent`, `.photoRequested`, `.voiceUsed`, `.callStarted`, `.profileOpened`, `.characterCreated`

- [ ] **Step 1: Write `PlummTips.swift`**

```swift
//
//  PlummTips.swift
//  First-run feature hints (Apple TipKit). Tips appear contextually the first
//  time a user reaches each control, roughly in usage order via event rules.
//  Configured ONLY after onboarding completes and never in review mode, so no
//  tip can fire during the onboarding flow or an App Review walkthrough.
//

import TipKit

enum PlummTips {
    // MARK: Events (donate at the real call sites)
    static let chatOpened      = Tips.Event(id: "chatOpened")
    static let messageSent     = Tips.Event(id: "messageSent")
    static let photoRequested  = Tips.Event(id: "photoRequested")
    static let voiceUsed       = Tips.Event(id: "voiceUsed")
    static let callStarted     = Tips.Event(id: "callStarted")
    static let profileOpened   = Tips.Event(id: "profileOpened")
    static let characterCreated = Tips.Event(id: "characterCreated")

    private static var configured = false

    static func configureIfEligible(onboardingCompleted: Bool) {
        guard !configured, onboardingCompleted, !ReviewModeService.isActive else { return }
        configured = true
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault),
        ])
    }
}

struct SendFirstMessageTip: Tip {
    var title: Text { Text("Say hi") }
    var message: Text? { Text("Type below to start the conversation. Each message costs \(TokenCosts.message) token.") }
    var rules: [Rule] {
        #Rule(PlummTips.chatOpened) { $0.donations.count >= 1 }
        #Rule(PlummTips.messageSent) { $0.donations.isEmpty }
    }
}

struct RequestPhotoTip: Tip {
    var title: Text { Text("Ask for a photo") }
    var message: Text? { Text("Tap the camera to ask for a picture — \(TokenCosts.photo) tokens.") }
    var rules: [Rule] {
        #Rule(PlummTips.messageSent) { $0.donations.count >= 3 }
        #Rule(PlummTips.photoRequested) { $0.donations.isEmpty }
    }
}

struct VoiceMessageTip: Tip {
    var title: Text { Text("Send a voice message") }
    var message: Text? { Text("Hold to record. She replies in her own voice — \(TokenCosts.voiceMessage) tokens.") }
    var rules: [Rule] {
        #Rule(PlummTips.photoRequested) { $0.donations.count >= 1 }
        #Rule(PlummTips.voiceUsed) { $0.donations.isEmpty }
    }
}

struct VoiceCallTip: Tip {
    var title: Text { Text("Call her") }
    var message: Text? { Text("Start a live voice call. \(TokenCosts.voiceCallPerMinute) tokens per minute.") }
    var rules: [Rule] {
        #Rule(PlummTips.voiceUsed) { $0.donations.count >= 1 }
        #Rule(PlummTips.callStarted) { $0.donations.isEmpty }
    }
}

struct TokenBadgeTip: Tip {
    var title: Text { Text("These are your tokens") }
    var message: Text? { Text("Messages, photos, calls and boosts spend them. Tap to see every price and top up.") }
    var rules: [Rule] {
        #Rule(PlummTips.messageSent) { $0.donations.count >= 1 }
    }
}

struct LevelSectionTip: Tip {
    var title: Text { Text("Your closeness level") }
    var message: Text? { Text("It grows as you chat. You can also spend tokens to jump ahead.") }
    var rules: [Rule] {
        #Rule(PlummTips.profileOpened) { $0.donations.count >= 1 }
    }
}

struct CreateCharacterTip: Tip {
    var title: Text { Text("Make your own") }
    var message: Text? { Text("Design a character from scratch — \(TokenCosts.characterCreation) tokens.") }
    var rules: [Rule] {
        #Rule(PlummTips.messageSent) { $0.donations.count >= 5 }
        #Rule(PlummTips.characterCreated) { $0.donations.isEmpty }
    }
}
```

(If `ReviewModeService.isActive` is not the exact API, check `Plumm/Services/ReviewModeService.swift` for the correct accessor and use it.)

- [ ] **Step 2: Configure at launch**

In `PlummApp.swift`, inside the existing launch `.task` (where `PurchaseService.shared.refreshServerTier()` etc. run), add:

```swift
PlummTips.configureIfEligible(onboardingCompleted: onboarding.isCompleted)
```

`onboarding` is already an `@State` on `PlummApp`. Also call it in `.onChange(of: onboarding.isCompleted)` so a user finishing onboarding this session gets tips configured without a relaunch:

```swift
.onChange(of: onboarding.isCompleted) { _, done in
    PlummTips.configureIfEligible(onboardingCompleted: done)
}
```

- [ ] **Step 3: Build**

Run the build. Expected: succeeds (no anchor wiring yet — Task 10).

- [ ] **Step 4: Commit**

```bash
git add Plumm/Services/Tips/PlummTips.swift Plumm/PlummApp.swift
git commit -m "feat(tips): TipKit tip definitions + onboarding-gated configuration"
```

---

## Task 10: Wire tip anchors + event donations + dev reset

**Files:**
- Modify: `Plumm/Views/ChatView.swift` (chat input, photo button, voice button, call button, token badge; `chatOpened` on appear)
- Modify: `Plumm/ViewModels/ChatViewModel.swift` (`messageSent`, `photoRequested`, `voiceUsed` donations at the existing send/photo/voice paths)
- Modify: `Plumm/Views/CharacterProfileView.swift` (`.popoverTip(LevelSectionTip())` on `relationshipSection`; `profileOpened` donation)
- Modify: the create-character entry button (`Plumm/Views/FeedView.swift` or `ExploreView.swift` or `CreateCharacterView.swift` presenter) — `.popoverTip(CreateCharacterTip())` + `characterCreated` donation on success
- Modify: `Plumm/Views/ProfileView.swift` (dev "Reset feature tips" row)
- Modify: voice-call start path (`Plumm/Views/VoiceCallView.swift` or `CallService`) — `callStarted` donation

**Interfaces:**
- Consumes: everything from Task 9.

- [ ] **Step 1: Donate events at the real call sites**

- `ChatView` body `.onAppear` (or the existing `.task`): `PlummTips.chatOpened.donate()`.
- `ChatViewModel.send(...)` — after a user message is appended: `await PlummTips.messageSent.donate()`.
- `ChatViewModel` photo-request path (where `chat-image` is called): `await PlummTips.photoRequested.donate()`.
- `ChatViewModel` voice-message path: `await PlummTips.voiceUsed.donate()`.
- Voice-call start (`CallService.start` success or `VoiceCallView.onAppear`): `await PlummTips.callStarted.donate()`.
- `CharacterProfileView` `.onAppear` (next to the existing `character_profile_viewed` log): `PlummTips.profileOpened.donate()`.
- Character-creation success handler: `await PlummTips.characterCreated.donate()`.

- [ ] **Step 2: Attach `.popoverTip` to anchors**

- Chat text field / send area → `.popoverTip(SendFirstMessageTip(), arrowEdge: .bottom)`
- Photo button → `.popoverTip(RequestPhotoTip())`
- Voice button → `.popoverTip(VoiceMessageTip())`
- Call button (chat header) → `.popoverTip(VoiceCallTip())`
- `TokenBadge` in chat header → `.popoverTip(TokenBadgeTip())`
- `relationshipSection` in `CharacterProfileView` → `.popoverTip(LevelSectionTip())`
- Create-character button → `.popoverTip(CreateCharacterTip())`

For each tip that maps to a concrete action, invalidate on tap, e.g. in the photo button action: `RequestPhotoTip().invalidate(reason: .actionPerformed)`.

- [ ] **Step 3: Dev reset row**

In `ProfileView`'s existing debug/dev section (guarded by whatever flag the file already uses for dev-only rows — search for `#if DEBUG` or a review/dev toggle):

```swift
Button("Reset feature tips") {
    try? Tips.resetDatastore()
}
```

Add `import TipKit` to `ProfileView.swift`.

- [ ] **Step 4: Build + manual check on a clean simulator**

Erase the simulator (Device → Erase All Content and Settings) or delete the app. Build & run. Complete onboarding. Then:
- Open a chat → "Say hi" tip on the input bar. Send a message → tip goes away.
- Token badge shows "These are your tokens" after the first message.
- Send 3 messages → "Ask for a photo" on the camera button.
- Open a character profile → "Your closeness level" on the RELATIONSHIP section.
- Settings → "Reset feature tips" → reopen chat → the tip returns.
- Kill & relaunch mid-onboarding (before completion): **no tips appear.**

- [ ] **Step 5: Commit**

```bash
git add Plumm/Views/ChatView.swift Plumm/ViewModels/ChatViewModel.swift Plumm/Views/CharacterProfileView.swift Plumm/Views/ProfileView.swift Plumm/Views/FeedView.swift Plumm/Views/VoiceCallView.swift
git commit -m "feat(tips): wire TipKit anchors, event donations, and dev reset"
```

---

## Self-Review

**1. Spec coverage**

| Spec section | Task(s) |
|---|---|
| Item 1 — server fix | Task 1 |
| Item 1 — client typed failure | Task 8 |
| Item 3 — role-aware names | Tasks 5, 6 |
| Item 3 — stageName status-term review | Task 5 Step 1-2 |
| Item 2 — profile RELATIONSHIP section | Task 7 |
| Item 2 — hero circle caption | Task 7 Step 3 |
| Item 2 — explanatory boost copy | Task 6 Step 3 |
| Item 2 — TipKit hint on section | Task 10 Step 2 (`LevelSectionTip`) |
| Item 4 — TipKit config + tips | Tasks 9, 10 |
| Item 4 — onboarding/review gate | Task 9 Step 1-2 |
| Item 4 — dev reset | Task 10 Step 3 |
| Item 5 — `TokenCosts` model | Task 2 |
| Item 5 — replace literals | Task 3 |
| Item 5 — `TokenCostsView` + entry points | Task 4 |
| Item 5 — inline cost labels | Task 3 Step 3 |

No gaps.

**2. Placeholder scan** — Copy for `stageName` / blurbs is concrete in Task 5 (flagged for a yes/no, not left blank). Anchor file paths in Task 10 include "or" alternates because the create-character presenter and call-start site need a one-line grep to pin down; each alternate is named. No "TBD"/"handle edge cases"/"similar to Task N".

**3. Type consistency** — `BoostOutcome` defined in Task 8, consumed only in Task 8. `RelationshipLevelsView` gains `role: String` in Task 6; the `CharacterProfileView` call site is updated in the same task (Step 4) and refined in Task 7. `TokenCosts.levelBoost(toLevel:)` — same label in Tasks 2, 3, 6, 9. `PlummTips` event names identical across Tasks 9 and 10. `Relationship.stageBlurb(_:)` defined Task 5, used Task 6.

**4. Ordering note** — Task 6 depends on Task 5 (blurbs) and Task 3 (`TokenCosts` for the cost label). Task 7 depends on Task 6 (`role` param). Tasks 9-10 depend on Task 2 (`TokenCosts` in tip copy). Task 8 is independent of 5-7 and can run any time after Task 1's context is understood. Recommended sequence: **1, 2, 3, 4, 5, 6, 7, 8, 9, 10**.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-09-02-token-economy-and-first-run-ux.md`. Two execution options:

1. **Subagent-Driven (recommended)** — a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — tasks run in this session via executing-plans, batched with checkpoints.

Deferred until the session limit resets, per your call.
