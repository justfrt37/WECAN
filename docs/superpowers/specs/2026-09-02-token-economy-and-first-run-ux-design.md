# Token Economy Visibility, Relationship-Level Rework & First-Run Feature Tour — Design

**Date:** 2026-09-02
**Branch:** `furkan_dev`
**Status:** Approved for planning (execution deferred until session limit resets)

## Context

Five related problems around discoverability and the token economy, raised
2026-09-02:

1. **Level-up-with-tokens is server-broken.** Tapping "Boost" on
   `RelationshipLevelsView` always redirects to the token store, even with a
   large balance and an active Pro Max subscription.
2. **The level / boost screen is not discoverable.** It only opens by tapping a
   small unlabeled 64pt circle in the character profile hero. Users do not know
   it exists or what it does.
3. **Relationship level names are romance-status framed** — `Lovers`,
   `Committed`, `Engaged`. Not wanted as the default ladder.
4. **No first-run guidance.** New users get no introduction to the app's
   features (photo requests, voice, calls, level, tokens, character creation).
5. **Token costs are invisible to users.** `message` = 1, `photo` = 25,
   `voice message` = 12, `voice call` = 3/sec, `character creation` = 50,
   `level boost` = 50/100/200 all live only in server + client code. Users spend
   without knowing the price.

Supabase is down until ~2026-09-02 evening; server-side changes here are written
now and deployed when it returns. All client-side work is unblocked.

## Root cause — item 1 (the boost bug)

`supabase/functions/level-boost/index.ts:79-83`:

```ts
const { data: charged } = await db.rpc("charge_tokens", {
  p_user_id: uid, p_amount: cost, p_reason: "level_boost",
});
if (!charged) return json({ error: "insufficient_tokens" }, 402);
```

`token_transactions.reason` has a CHECK constraint
(`token_transactions_reason_check`) allowing only:
`message, voice, photo, streak, purchase, subscription_grant, welcome, debug,
character_creation` (see
`supabase/migrations/025_character_creation_reason.sql`).

`"level_boost"` is not in the list. Inside `charge_tokens()` (a plpgsql
`security definer` function, `supabase/migrations/006_token_system.sql:49`) the
balance is decremented, then `insert into token_transactions … reason
'level_boost'` raises a check-constraint violation. The exception aborts the
whole function and rolls back its work, so the RPC call returns `null`. The edge
function reads `!charged` → returns `402 insufficient_tokens`. The client
(`ChatService.boostLevel`) turns any non-2xx into `nil`, and
`RelationshipLevelsView.boost()` treats `nil` as "insufficient" → routes to the
token store.

This is byte-identical to the `character_creation` bug that migration 025 fixed;
that migration's own comment predicted "expect more features to gate the same
way." Pro Max and the 7k balance are red herrings — level-boost is tier-agnostic
and the balance check is never the thing that fails.

An audit of every `charge_tokens` / `grant_tokens` caller confirms `level_boost`
is the **only** reason string currently outside the allowlist:

| Edge function | reason | in allowlist? |
|---|---|---|
| `chat/index.ts:1468` | `message` | yes |
| `chat-image/index.ts:699` | `photo` | yes |
| `voice-message-tts/index.ts:143,191` | `voice` | yes |
| `voice-call-start/index.ts:105`, `voice-call-end/index.ts:138` | `voice` | yes |
| `create-character/index.ts:405` | `character_creation` | yes |
| `_shared/subscriptionSync.ts:157` | `subscription_grant` | yes |
| `purchase-tokens/index.ts:138` | `purchase` (grant) | yes |
| **`level-boost/index.ts:82`** | **`level_boost`** | **NO** |

## Non-goals

- No change to how levels are *earned* through chat (server
  `applyRelationshipGain` in `chat/index.ts` is untouched).
- No change to the token *charging* amounts or the server as source of truth for
  balances.
- No full-screen forced walkthrough. TipKit shows contextual tips as the user
  reaches each screen; a linear spotlight tour is explicitly out of scope (this
  is a known TipKit limitation and an accepted trade-off).
- No new romantic / "engaged" progression track. The design leaves room for one
  later (see item 3) but does not build it.
- Nickname pricing: nicknames are a Pro+/Max entitlement with no token charge
  (`set-nickname` uses `requireNicknameEntitlement`, never `charge_tokens`), so
  the costs screen lists it as "Pro+ feature", not a token price.

---

## Item 1 — Fix the boost bug

### Server

New migration `supabase/migrations/028_level_boost_reason.sql`: drop and
re-create `token_transactions_reason_check` adding `'level_boost'`. Same
drop/add pattern as migrations 007 and 025.

```sql
alter table token_transactions drop constraint token_transactions_reason_check;
alter table token_transactions add constraint token_transactions_reason_check
  check (reason in ('message','voice','photo','streak','purchase',
                    'subscription_grant','welcome','debug','character_creation',
                    'level_boost'));
```

Deploy: `npx supabase db push` (or apply via MCP) once Supabase is back. No edge
function redeploy needed — `level-boost/index.ts` is already correct.

### Client — make the failure legible

`ChatService.boostLevel` currently collapses every non-success into `nil`, so a
transient network error, a 500, a 404 "conversation_not_found", and a real 402
all look the same to the UI and all send the user to the token store. Change it
to return a typed result:

```swift
enum BoostOutcome {
    case success(LevelBoostResult)
    case insufficientTokens        // real 402
    case alreadyMaxLevel           // 400 already_max_level
    case failed                    // network / 5xx / decode — "try again"
}
```

`RelationshipLevelsView` then:
- `.success` → apply, as today.
- `.insufficientTokens` → existing `onInsufficientTokens()` (token store / paywall).
- `.alreadyMaxLevel` → disable the button, no redirect.
- `.failed` → inline error ("Couldn't boost — check your connection and try
  again"), no redirect.

This prevents the whole class of "silent misdirect to the store" bugs from
recurring, independent of the server fix.

### Verification

- Unit-testable: `boostCost(forTargetLevel:)` client vs server parity (both
  50/100/200 by target level — keep in sync via `TokenCosts`, item 5).
- Manual, post-deploy: Pro Max account with ample balance boosts L1→L2, balance
  drops by 50, `token_transactions` row written with `reason='level_boost'`,
  screen updates without a store redirect.

---

## Item 2 & 3 — Relationship levels: role-aware names + discoverability

### 3 — Role-aware names everywhere

`Relationship.stageName(_ level: Int, role: String)` already exists
(`Plumm/Models/Relationship.swift`) and is already used by `ChatViewModel`
(`relationshipStage`, level-up events). It has a per-role ladder for
`distant / shy / playful / devoted / crazy / ex / flirty`.

`RelationshipLevelsView` ignores it and hardcodes a separate list,
`relationshipLevels: [RelationshipLevel]` (lines 18-29), with
`Strangers … Lovers … Committed … Engaged … Soulmates` plus a one-line `blurb`
per level. This is the list the user objects to, and it is a second source of
truth for level naming.

**Change:**

1. Delete the hardcoded `relationshipLevels` array.
2. `RelationshipLevelsView` gains a `role: String` parameter; the caller
   (`CharacterProfileView`) passes `character.personalityRole`.
3. Row title comes from `Relationship.stageName(level, role: role)`.
4. Blurbs: add `Relationship.stageBlurb(_ level: Int) -> String` — **ten
   role-agnostic, closeness-framed strings**, no marriage/engagement/
   relationship-status words. The role supplies the flavor via the name; the
   blurb just describes how deep the bond is at that step. Example direction
   (final copy in the plan, for user review):
   - L1 "You've just met — first impressions."
   - L5 "Something warmer is starting to show."
   - L8 "You share things you don't tell anyone else."
   - L10 "As close as two people get."
5. Review pass over `Relationship.stageName` itself: replace remaining
   civil-status terms in the role ladders (`flirty`: "Potential Partner",
   "Partner", "Serious Relationship"; `devoted`: "My Everything"; `crazy`:
   "Crazy Love"; `ex`: "Back Together") with closeness/emotion terms of the
   same intent. Keep role character (a `crazy` bot still escalates to
   "Obsessive"). The replacement table goes in the plan for user sign-off
   before edit — this is copy, reviewed not guessed.
6. `stageName` keeps `role` defaulting to `"flirty"` for existing callers;
   `#Preview` and any sample paths pass an explicit role.

Server directives (`conversation_behaviors` / role+level scripts consumed by
`fetchDirective`) are **not** touched — they tune *behavior*, not the label the
user sees, and the user's objection is about the visible ladder.

**Future romantic track (not built):** if wanted later, add a parallel
`Relationship.romanticStageName` / a per-conversation `track` flag; the
`stageName(level:role:)` signature already isolates naming so a third argument
or a sibling function is a contained change.

### 2 — Discoverability

Three additions, smallest-footprint:

1. **Labeled section in the profile body.** `CharacterProfileView` currently
   surfaces level only as the hero circle. Add a `RELATIONSHIP` section
   (same visual language as `ABOUT` / `INTERESTS`) below `about`:
   `Level N · <stageName>` with a short progress bar (reusing
   `userLevelProgress`) and a "View progress" button that opens the same
   `showLevels` sheet. This is the primary discoverable entry point.
2. **Keep the hero circle**, add a 10pt caption "Tap for levels" under it.
3. **Explanatory header in `RelationshipLevelsView`.** The current subtitle
   ("As you chat your level rises…") does not mention the boost. Add a line:
   "Chat to grow closer over time — or spend tokens to jump ahead now." Shown
   whenever `currentLevel < maxLevel`.
4. **TipKit hint** on the profile RELATIONSHIP section (see item 4):
   `LevelSectionTip` — "See how close you are and boost instantly with tokens."

Analytics: `EventLogger.shared.log("feature_used", ["feature":
"relationship_levels_opened", "source": <"profile_section"|"hero_circle">])`.

---

## Item 4 — First-run feature tour (Apple TipKit)

### Approach

Apple **TipKit** (deployment target is already iOS 17.0). Contextual
`popoverTip` bubbles anchored to real controls, appearing the first time a user
reaches each screen, in a rough sequence enforced by event/parameter rules.
Persistence, frequency, and eligibility are handled by the TipKit datastore.
Each tip is dismissable by its built-in close control or tapping away
("skippable by pressing some places").

### Components

**`Plumm/Services/Tips/PlummTips.swift`** — new file:

- `enum PlummTipEvents` — `Tips.Event` donations:
  `chatOpened`, `messageSent`, `photoRequested`, `voiceUsed`, `callStarted`,
  `profileOpened`, `characterCreated`.
- One `Tip` struct per hint, each with `rules` referencing the events:

  | Tip | Anchored on | Shows when |
  |---|---|---|
  | `SendFirstMessageTip` | chat input bar | `chatOpened` ≥ 1 AND `messageSent` == 0 |
  | `RequestPhotoTip` | photo button (chat) | `messageSent` ≥ 3 AND `photoRequested` == 0 |
  | `VoiceMessageTip` | mic/voice button (chat) | `photoRequested` ≥ 1 AND `voiceUsed` == 0 |
  | `VoiceCallTip` | call button (chat header) | `voiceUsed` ≥ 1 AND `callStarted` == 0 |
  | `TokenBadgeTip` | token badge (chat header) | `messageSent` ≥ 1, once |
  | `LevelSectionTip` | profile RELATIONSHIP section | `profileOpened` ≥ 1, once |
  | `CreateCharacterTip` | create button (Discover/Explore) | `messageSent` ≥ 5 AND `characterCreated` == 0 |

  YAGNI: no tip for tab bar items, likes, settings.

- Each tip is invalidated (`.invalidate(reason: .actionPerformed)`) when the
  user performs its action, so it never re-shows.

**`Tips.configure`** in `PlummApp` `.task`, **only** when
`onboarding.isCompleted == true` and review mode is off
(`ReviewModeService`). `displayFrequency(.immediate)`, default datastore
location. If the gate is not satisfied, TipKit is never configured, so no tip
can appear during onboarding or review.

**View changes:** add `.popoverTip(SomeTip())` to the seven anchor views and
donate the matching events at the call sites that already exist
(`ChatView.onAppear` → `chatOpened`; `ChatViewModel.send` → `messageSent`;
etc.).

**Dev affordance:** a "Reset feature tips" row in `ProfileView`'s existing
debug/dev section calling `try? Tips.resetDatastore()`.

**Analytics (optional, cheap):** a `for await` on each tip's `statusUpdates`
in `PlummTips`, logging `feature_used` / `feature = "tip_<name>_shown"`.

### Trade-offs

- Not a linear "next / next / next" tour — tips are spread across natural usage.
  Accepted per the tech choice.
- TipKit visual style is Apple's; limited customization. Accepted.
- iOS 17.0: `popoverTip`, `Tips.configure`, `Tips.Event`, `resetDatastore` are
  all available from 17.0. No `#available` fences needed given the 17.0 floor.

---

## Item 5 — Token cost visibility

### Single client-side display source

**`Plumm/Models/TokenCosts.swift`** — new file, display-only constants that
mirror the server. Server stays authoritative for actual charges; this is what
the UI shows and what client-side pre-checks use.

```swift
enum TokenCosts {
    static let message = 1               // chat/index.ts
    static let photo = 25                // chat-image/index.ts
    static let voiceMessage = 12         // voice-message-tts/index.ts
    static let voiceCallPerMinute = 180  // voice-call-* : 3 tokens/sec
    static let characterCreation = 50    // create-character/index.ts CREATION_COST

    /// level-boost/index.ts costForTargetLevel
    static func levelBoost(toLevel level: Int) -> Int {
        if level <= 5 { return 50 }
        if level <= 8 { return 100 }
        return 200
    }
}
```

Header comment: "Display + client pre-check only. Server is the source of truth
for charging. Keep in sync with the cited edge functions — a mismatch here is
cosmetic, a mismatch in the edge function is real."

Replace scattered literals: `RelationshipLevelsView.boostCost` → `TokenCosts.
levelBoost`; any hardcoded photo/voice cost in `ChatView` / `ChatViewModel`
badges → `TokenCosts`.

### Dedicated screen

**`Plumm/Views/TokenCostsView.swift`** — a plain list:

- Rows: Message (1), Photo request (25), Voice message (12), Voice call
  (180 / min), Create a character (50), Boost relationship level (50–200),
  Nicknames (Pro+ feature — no token cost).
- Short "how to earn" footer: daily streak claim + purchases, linking to the
  token store.
- Coin icon per row, values from `TokenCosts`.

**Entry points:**
- `TokenStoreView` header — an info button (`"info.circle"`) opening
  `TokenCostsView` as a sheet.
- `ProfileView` (Settings) — a "Token costs" row.

### Inline (small)

Ensure every paid action button shows its cost the way the boost button already
does: verify/extend the photo and voice buttons in `ChatView` to carry a
`"25 🪙"` / `"12 🪙"` sub-label (or a tooltip via `TokenBadgeTip`). Low effort,
bundled here.

---

## Rollout / ordering

Client items (2, 3, 4, 5, and the client half of 1) ship independent of
Supabase. Item 1's migration is written now, applied when Supabase returns.
Suggested phase order in the plan: **1 → 5 → 3 → 2 → 4** (bug first; costs model
underpins 3's boost copy; naming before the screen that shows it; tour last so
it can point at the finished RELATIONSHIP section).

## Testing summary

- **Unit:** `TokenCosts.levelBoost` vs server table; `Relationship.stageName`
  returns non-status strings for all role×level; `Relationship.stageBlurb`
  covers 1…10.
- **Manual (no Supabase):** profile RELATIONSHIP section opens the sheet;
  role-correct names for a `crazy` vs `shy` character; TipKit tips appear in
  order on a fresh simulator, none during onboarding, reset row works;
  `TokenCostsView` reachable from both entry points.
- **Manual (post-deploy):** boost happy path on Pro Max + funded account;
  `token_transactions` row; typed-failure paths (airplane mode → "try again",
  not a store redirect).
