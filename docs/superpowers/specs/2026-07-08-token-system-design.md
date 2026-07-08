# Token System Design

**Date:** 2026-07-08
**Status:** Approved (visual mockups reviewed in browser companion), ready for implementation planning.

## Summary

Replace the current no-cost chat / dead RevenueCat skeleton with a real token economy: every message, voice reply, and photo costs tokens; tokens are earned free via a daily login streak or bought outright; three subscription tiers give a much cheaper weekly token drip plus the ability to create new characters (a feature otherwise fully locked). A persistent token badge lives in the header of every screen and opens the token/subscription page.

## Goals

- Meter the app's real variable cost (Grok text, TTS, xAI image generation) against a token currency the user understands and pays for.
- Make subscribing clearly cheaper per-token than buying tokens outright, without making outright purchases feel like a ripoff.
- Gate character creation entirely behind a paid tier, with a weekly creation allowance per tier.
- Give every user (including non-payers) a reason to open the app daily via a streak-multiplied free token grant, without that grant being exploitable by clock/timezone manipulation.
- Ship a single persistent, tappable token indicator that is present on every screen without exception.

## Non-goals / explicitly out of scope

- Actually configuring App Store Connect subscription products or the RevenueCat dashboard (entitlements, offerings, products) — this requires the user's own Apple Developer / RevenueCat accounts and cannot be done by an agent.
- Adding the RevenueCat SDK package in Xcode — requires Xcode, unavailable in this sandbox (per existing project constraint, see `PurchaseService.swift`'s setup comment).
- Real end-to-end purchase testing (StoreKit sandbox) — requires Xcode/TestFlight.
- Retroactively charging tokens for anything that already happened before this ships.

The implementation will follow the same pattern the existing `PurchaseService`/`PaywallHostView` skeleton already uses: everything is coded and wired end-to-end, gated behind `canImport(RevenueCat)` / an empty API key, so the project keeps compiling and the token/UI logic is fully exercised even before the user completes the external RevenueCat/App Store setup. Once they add the SDK and fill in the API key + entitlement IDs, no further code changes are needed — this mirrors the existing documented setup flow.

## Token economy

Internal accounting peg: **1 token ≈ $0.001 of raw API cost.** This is never shown to the user — it's just how the numbers below were derived, so future action types can be priced consistently.

### Real API costs (researched 2026-07-08)

| Provider | Rate | Source |
|---|---|---|
| Grok 4.1 Fast (this app's model) | $0.20 / 1M input tokens, $0.50 / 1M output tokens | xAI pricing docs |
| Google TTS Chirp3-HD | $0.00003 / character | Google Cloud pricing |
| ElevenLabs v3 | $0.0001 / character | ElevenLabs pricing |
| xAI image generation | $0.02 / image (flat, both 1K and 2K) | existing code comment in `create-character/index.ts`, verified against xAI docs |

### Per-action token costs

| Action | Tokens | Basis |
|---|---|---|
| Text message (send) | 1 | ~$0.0005–0.001 per turn (system prompt + history + reply) |
| Voice message (send) | 12 | ~$0.006–0.016 per turn (text gen + TTS, either provider) |
| Photo message (send) | 25 | ~$0.022 (prompt-composition call + image gen + caption call) |
| Character creation | 0 tokens — gated by subscription tier + weekly slot limit instead (see below) | bio/image/schedule gen is a subscriber perk, not metered per-use |

These three deduction points map directly to `ChatViewModel.send()`, `sendVoiceRequest()`, and `sendImageRequest()`.

### Where deduction must happen

**Server-side, atomically, in the edge functions** (`chat`, `chat-image`, `voice-message-tts`) — never client-side. The client cannot be trusted to decrement its own spending. Each of these functions must, at the start of the request:

1. Look up the caller's current token balance (via `auth.uid()`).
2. Reject with a specific error code (e.g. `insufficient_tokens`) if balance < action cost, before doing any paid API work.
3. Deduct the cost and record a ledger row atomically with the response, once the paid work succeeds (not before — a failed Grok/TTS/image call shouldn't cost the user tokens).

The client checks balance optimistically (to grey out the send button before even trying), but the edge function is the actual source of truth and final gate.

### Data model (new)

- **`token_balances`**: `user_id` (PK, references auth.users), `balance` (int, not null, default 0), `updated_at`.
- **`token_transactions`**: `id`, `user_id`, `delta` (int, positive for grants/purchases, negative for spends), `reason` (text: `message`, `voice`, `photo`, `streak`, `purchase`, `subscription_grant`), `created_at`. Append-only ledger — never updated, only inserted. Exists for debugging/support/audit, not read by the client UI directly (balance itself is read from `token_balances`).
- RLS on both: `user_id = auth.uid()`, `SELECT` only for the client. All `INSERT`/`UPDATE` happen via `service_role` inside edge functions — the client never writes its own balance, exactly like `conversations.relationship_level` today.

## Daily streak (free tokens)

- Base grant: **10 tokens/day**, multiplied by the current **consecutive-day streak**:
  - Day 1: ×1 (10 tokens)
  - Days 2–4: ×2 (20 tokens)
  - Days 5–6: ×3 (30 tokens)
  - Day 7: ×5 (50 tokens)
  - Missing a day resets the streak counter to 1 (next claim starts the ladder over at day 1).
- **Popup UI**: a Monday–Sunday row of 7 boxes. Boxes already claimed *this calendar week* are lit up; the current day's box shows its multiplier. This weekly grid is purely cosmetic/display — it resets every Monday regardless of streak status, so the display always matches "this week" even if the underlying consecutive-streak counter is mid-cycle from the prior week.
- User taps to collect, popup closes. One claim per calendar day (local time, see below).

### Anti-abuse (local time vs. UTC)

This cannot be a client-only `UserDefaults` store like the app's other lightweight prefs (`BlockedCharactersStore`, `PassedCharactersStore`) — it's real currency-adjacent state, so it needs a server-side row per user, same tier of trust as `token_balances`.

- **New table `streak_state`**: `user_id` (PK), `current_streak` (int), `last_claim_at` (timestamptz, UTC), `last_claimed_local_date` (text, e.g. `"2026-07-08"`, as reported by the client).
- **Display** (which days light up, "today"'s multiplier): computed from the client's own local calendar date — purely cosmetic, so the UI feels correct regardless of the user's timezone.
- **Grant eligibility** (does an edge function actually deduct... i.e. *credit* tokens): gated by the server's own UTC clock — a claim is only accepted if `now() - last_claim_at >= 20 hours` (deliberately just under 24h so a user in any timezone isn't punished for opening slightly earlier each day, but a manipulated device clock jumping forward by days at a time, or jumping back to reclaim, cannot produce more than one grant per real ~20-hour window). If the client-reported local date has advanced by more than 1 day relative to the last claim (e.g. device clock jumped forward a week), the server caps the streak-continuation logic — it still grants (once, per the elapsed-time gate), but treats the streak as broken (resets to day 1) rather than rewarding the jump.
- This is enforced in a new edge function, `claim-streak`, not client-side math.

## Character creation gating

- Character creation is **only available to active subscribers** (any of the three tiers) — free/non-subscribed users cannot create a character at all, and never spend tokens on it either way.
- Each tier gets a **weekly creation allowance** that resets every 7 days from the subscription's renewal date: Pro = 1/week, Pro+ = 3/week, Max = 10/week.
- Enforcement: `create-character`'s edge function checks (a) the caller has an active entitlement (from RevenueCat webhook-synced subscription status — see Dependencies) and (b) `count(characters where created_by = auth.uid() and created_at >= start_of_current_billing_week) < tier_limit`. No new table needed for slot tracking — it's a count against the existing `characters` table.
- **UI reuse**: exactly the existing blur-and-reveal paywall trigger already coded in `CreateCharacterView.reveal()` (`guard PurchaseService.shared.isPro else { showPaywall = true; return }`) — extended so the guard also checks "has an unused slot this week," and `showPaywall` opens the same token/subscription page described below (not a separate paywall screen).

## Persistent token badge

- Truly every screen, per the original ask — not just the 5 main tabs. That includes the fullScreenCover-presented views that live outside `MainTabView`'s `NavigationStack` (`CreateCharacterView`, `CharacterProfileView`, `GalleryView`, `AddCharacterNoteSheet`, `HelpSupportView`, etc.), not only `MainTabView`'s tab bar destinations and `ChatView`.
- The one screen it's *not* shown on is the token/subscription page itself (redundant — you're already there).
- Implementation: a single reusable `TokenBadge` view + a `.tokenBadge()` view modifier (top-trailing overlay) applied at each screen's own top-level container, mirroring how `headerButton`/`circleButton` are already duplicated per-view in this codebase rather than centralized — consistent with existing patterns, not a new architectural layer. The plan should decide the exact modifier call sites (every `View`'s top-level `body`), but the requirement is: no screen may render without it, including modals.
- Rectangular pill: token count on the left, a smaller square "+" box on the right, both inside one tappable container — tapping anywhere on the pill (count or the `+` box) opens the token/subscription page. Not two separate tap targets.
- Reads live from `token_balances` (cached locally like other stores, refreshed on relevant events — after sending a message/voice/photo, after a purchase, after a streak claim).

## Token / subscription page

Confirmed via visual mockup (`paywall-phone-v3.html` in this session's brainstorm archive):

- **Weekly / Annual toggle** at the top. Switching it only changes the prices shown on the three tier cards — token amounts and character-slot perks per tier are identical either way.
- **Three tier cards, stacked vertically, tap-to-select** (radio indicator + gold border/highlight on the selected card), not three separate buttons. Pro+ is pre-selected by default and marked "Most Popular." Each card lists its benefits as a checklist in plain text (no icon standing in for "character creation" — spelled out, e.g. "Create 3 new characters per week").
- **One sticky "Continue" button pinned to the bottom of the screen**, reflecting whichever tier is currently selected (e.g. "Continue — Pro+ $14.99/wk"). This is the only subscription-purchase action on the page.
- Below the subscription section, a **row of three one-time token packs** (Small/Medium/Large), each with its own independent "Buy" button — these are separate one-tap in-app purchases, not part of the tier-selection/sticky-button flow.

### Pricing

| Tier | Weekly | Annual | Tokens/week | Character slots/week | Effective $/token | Margin over $0.001 cost |
|---|---|---|---|---|---|---|
| Pro | $6.99 | $59.99 | 1,000 | 1 | $0.00699 | ~7x |
| Pro+ | $14.99 | $119.99 | 2,500 | 3 | $0.00600 | ~6x |
| Max | $29.99 | $239.99 | 6,000 | 10 | $0.00500 | ~5x |

Annual price is a separate discounted number, not `weekly × 52` (a literal 52x multiplier produces an unusable sticker price like $363/year) — annual is priced at roughly the cost of ~8.5 weeks, i.e. a deep incentive to commit long-term, same tokens/perks either way.

| Token pack | Price | Tokens | $/token | Margin over $0.001 cost |
|---|---|---|---|---|
| Small | $5.99 | 300 | $0.01997 | ~20x |
| Medium | $19.99 | 1,000 | $0.01999 | ~20x |
| Large | $59.99 | 3,000 | $0.01997 | ~20x |

All three packs sit at a flat ~20x margin (no bulk discount) — simplest to reason about and matches the "aim for 20x" target literally rather than approximately.

## Dependencies / what the user must do outside this codebase

1. Create an Apple Developer subscription group with 3 auto-renewable subscription products × 2 durations (weekly/annual) = 6 App Store Connect products (or however RevenueCat's "packages" model wants them organized), plus 3 non-consumable or consumable IAP products for the token packs.
2. Create a RevenueCat project, wire the App Store Connect products into RevenueCat "Offerings," and create 3 entitlements (`pro`, `pro_plus`, `max`).
3. Add the RevenueCat SDK package in Xcode (documented steps already exist in `PurchaseService.swift`'s header comment).
4. Fill in the real RevenueCat public SDK key in `PurchaseService.apiKey`.
5. Set up a RevenueCat → Supabase webhook (or poll `customerInfo()` client-side, syncing entitlement status into a small `subscriptions` table) so edge functions can check tier/entitlement server-side without calling RevenueCat's API directly from Deno.

Until these are done, the app compiles and the entire token/streak/badge/paywall UI works, but every "subscribe" or "buy tokens" action will show the existing "coming soon" placeholder — exactly today's behavior, just with a real token balance and real per-message costs already live underneath it.

## Open items for the implementation plan to resolve

- Exact webhook vs. polling approach for syncing RevenueCat entitlement status server-side (needed for `create-character`'s tier/slot check) — an implementation detail, not a product decision, left for the plan.
- Whether `token_transactions` needs an index/retention policy — low priority, revisit if it grows large.
