# Optimistic UI, Background Prefetch & Durable Action Queue

Date: 2026-08-07
Status: Approved

## Goal

Make non-chat parts of the app feel instant: no spinners blocking navigation, photos
appear pre-loaded, and user actions (create character, claim streak, generate photo)
reflect in the UI immediately instead of waiting on a network round trip.

**Explicitly out of scope:** chat message send/receive UI (`ChatViewModel`, `ChatView`,
`MessageBubble`, `VoiceMessageBubble`, `VoiceCallView`) — carefully tuned already, not
to be touched. Also out of scope: `PurchaseService` (RevenueCat-owned state machine,
recent server-authoritative sync work) and the local-only Block/Pass/Like stores (no
server call exists today, nothing to make optimistic).

## Current State

- `Plumm/Services/ImageCache.swift` + `Plumm/Views/CachedImage.swift`: mature two-tier
  (memory `NSCache` + disk) image cache with downsampling and a bounded-concurrency
  `prefetch(_:)` method — but nothing calls `prefetch` proactively today; images load
  lazily on first render.
- No queueing/retry/background-task infrastructure anywhere in the app
  (`BGTaskScheduler`, generic retry queue, etc. — none exist). This work is greenfield.
- `CharacterStore` already has a `loadCachedCharacters()`/`saveCachedCharacters()` pair
  (CharacterStore.swift:252/257) but it's not used as "show cached instantly, refresh
  silently" — need to verify/extend usage.
- `TokenStore.refresh()` is in-memory only, no disk persistence, so token balance is
  blank/zero on cold launch until the network call returns.
- Real network mutations outside chat/purchase: `CharacterCreateService` (create
  character, 2 POSTs), `StreakService` (claim streak, 1 POST), `GenerateService` +
  `GeneratedPhotoService` (trigger + fetch generated photos).

## Phase 1 — Image Prefetch

- Call `ImageCache.prefetch(_:)` (existing method, ImageCache.swift:120) right after
  `CharacterStore.load()` / `refreshCharacters()` returns, for all character avatar and
  card photo URLs.
- Call `prefetch` after `GeneratedPhotoService.fetch` returns, for the fetched gallery
  photo URLs.
- In `FeedView`, `GalleryView`, `CharacterListView`: prefetch the next N items ahead of
  current scroll/swipe position (reuse existing bounded 5-concurrent prefetch).
- `CachedImage.swift:63` currently swallows failed loads silently (`try?`) — add one
  retry with a short backoff before giving up; still no infinite retry loop.
- Purely additive: no changes to `CachedImage`'s render path or existing call sites'
  behavior, so chat's use of `CachedImage` is unaffected.

## Phase 2 — Optimistic Infra

### 2A. Cache-first data (stale-while-revalidate)

For GET-heavy reads that currently block UI on network:

- `CharacterStore`: on load, show last-persisted snapshot instantly via existing
  `loadCachedCharacters()`, fire the network refresh in the background, diff and update
  UI when it lands. No blocking spinner on a warm cache.
- `TokenStore`: add disk persistence of last known balance (new — currently in-memory
  only). Show cached balance immediately on launch, refresh silently via `refresh()`.

### 2B. Durable optimistic-action queue

- `OptimisticAction` protocol: `apply()` (synchronous local UI mutation), `perform()
  async throws` (the actual network call), `rollback()` (revert local state on
  permanent failure).
- `ActionQueue` actor: persists pending actions as JSON to disk (Application Support
  directory), FIFO per action-type key. Processes on enqueue, on app launch, and on
  foreground.
- Retry policy: exponential backoff, max 3 attempts. On final failure: call
  `rollback()` and surface a generic (non-chat-styled) error banner/toast.
- Concrete actions wired to the queue:
  - **Create character** (`CharacterCreateService`): show new character in list
    immediately as an optimistic placeholder; swap in real data/photo when the POST
    returns; rollback removes the placeholder and shows an error banner.
  - **Claim streak** (`StreakService`): increment streak count/reward in UI instantly;
    rollback decrements and shows an error banner on failure.
  - **Trigger photo generation** (`GenerateService` / `GeneratedPhotoService`): show a
    "generating" placeholder card in the gallery immediately instead of waiting on the
    POST response; replace with the real photo once `GeneratedPhotoService.fetch`
    confirms it's ready; rollback removes the placeholder on failure.

## Phase 3 — Wiring

- Wire Phase 1 prefetch calls into `CharacterStore.load`/`refreshCharacters`,
  `GeneratedPhotoService.fetch`, and scroll-ahead logic in `FeedView`/`GalleryView`/
  `CharacterListView`.
- Wire Phase 2A into `CharacterStore` and `TokenStore`.
- Wire Phase 2B queue into `CreateCharacterView.swift` (character creation),
  `StreakPopupView.swift` (streak claim), and the gallery/generation trigger call site
  (`GalleryView.swift` or equivalent).
- Add one new generic, reusable toast/banner view for rollback-failure errors (not
  chat-styled — a plain top-level dismissible banner).

## Testing

No XCTest target found in the repo. Verification will be manual: build succeeds in
Xcode, and manual simulator runs covering:
- Character creation, streak claim, photo generation — confirm instant UI update.
- Kill app mid-flight after triggering an action — confirm the durable queue resumes
  and completes (or rolls back) on next launch.
- Character list / gallery scrolling — confirm images appear without visible
  lazy-load pop-in on a warm cache.
