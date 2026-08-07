# Background Image Prefetch (Scroll-Ahead)

Date: 2026-08-07
Status: Approved (descoped 2026-08-07 — see Revision below)

## Goal

Make photo-heavy scrolling feel instant: photos appear pre-loaded instead of
lazy-popping-in as the user scrolls/swipes.

**Explicitly out of scope:** chat message send/receive UI (`ChatViewModel`, `ChatView`,
`MessageBubble`, `VoiceMessageBubble`, `VoiceCallView`) — carefully tuned already, not
to be touched. Also out of scope: `PurchaseService` (RevenueCat-owned state machine,
recent server-authoritative sync work) and the local-only Block/Pass/Like stores (no
server call exists today, nothing to make optimistic).

## Revision (2026-08-07)

Original design proposed three phases: (1) image prefetch, (2A) cache-first data for
`CharacterStore`/`TokenStore`, (2B) a durable optimistic-action queue for character
creation / streak claim / photo generation. Investigation before planning found:

- **2A already exists.** `CharacterStore.load()` already shows the disk-cached
  character list instantly then refreshes in the background (CharacterStore.swift:
  110-157), and already prefetches card/avatar images on load (line 144-145).
  `TokenStore` already persists balance to `UserDefaults` and shows the cached value
  immediately on init (TokenStore.swift:27-29, 46). Nothing to build.
- **2B has no valid target.** `CharacterCreateService` has deliberate comments stating
  the caller must never optimistically create a local character — the server can
  reject (403, subscription required) or require more tokens (402), and a
  `decodeFailure` outcome exists specifically so the client re-fetches from the server
  instead of inventing a "ghost" character. Building optimistic creation here would
  fight this existing safety design. `StreakService.claim()` is already
  fire-and-forget/non-blocking (popup only shown after success) — nothing to make more
  optimistic. `GenerateService` is a synchronous wizard step; the actual photo
  generation trigger lives inside the chat flow, which is out of scope. No mutation in
  the app currently benefits from a durable retry queue, so building one would be
  speculative infra with no consumer (YAGNI) — dropped.

Remaining, real scope: Phase 1 (image prefetch) only, expanded below to scroll-ahead
prefetch since load-time prefetch already exists.

## Current State

- `Plumm/Services/ImageCache.swift` + `Plumm/Views/CachedImage.swift`: mature two-tier
  (memory `NSCache` + disk) image cache with downsampling and a bounded-concurrency
  `prefetch(_:)` method (5-concurrent, skips already-cached URLs).
- `CharacterStore.load()` already prefetches every character's card+avatar photo at
  launch (CharacterStore.swift:144-145) — deliberately does NOT prefetch gallery
  (generated) photos at launch, per an existing comment noting that prefetching
  everything bloated RAM.
- `FeedView`/`CharacterListView` checked and have no gap: `FeedView`'s deck draws its
  photos from the already-prefetched `CharacterStore.characters` set (and only ever
  renders current+next card, both already warm); `CharacterListView` is an unused
  legacy screen that renders SF Symbols only, no `CachedImage` at all. Neither needs
  changes.
- `GalleryView.swift:39-41`: fetches the user's own generated photos for one character
  (`GeneratedPhotoService.fetch`) then renders them in a `LazyVGrid` — each cell lazily
  triggers its own network load as it scrolls into view (pop-in). Not prefetched.
- `CharacterProfileView.swift:57-61,118-176,275-330`: the same `images` array (a
  character's pre-made gallery) is rendered twice — once in a swipeable hero `TabView`,
  once in a `photosSection` grid below. Photos locked behind PRO (`idx > 0 &&
  !isPro`) deliberately skip `CachedImage` entirely (a `frostedLockedFill` placeholder
  instead) so locked content is never downloaded — this must be preserved; only
  unlocked URLs should be prefetched.
- `CachedImage.swift:63` swallows failed network loads silently (`try?`) — no retry.

## Phase 1 — Image Prefetch

- `GalleryView`: after `GeneratedPhotoService.fetch` returns in `.task` (line 40), call
  `ImageCache.shared.prefetch(yourPhotos)` so the grid's photos are already warm before
  `LazyVGrid` scrolls them into view. Bounded — one character's own photos only.
- `CharacterProfileView`: on appear, call `ImageCache.shared.prefetch(_:)` with `images`
  filtered to unlocked URLs only (`idx == 0 || PurchaseService.shared.isPro`) — mirrors
  the existing per-index lock check so locked photos are still never downloaded.
- `CachedImage.swift:63` — add one retry with a short delay before giving up on a
  failed network load; still no infinite retry loop.
- Purely additive: no changes to `CachedImage`'s render path or existing call sites'
  behavior, so chat's use of `CachedImage` is unaffected.

## Testing

No XCTest target found in the repo. Verification will be manual: build succeeds in
Xcode, and manual simulator runs covering:
- Open a character's gallery (`GalleryView`) and profile (`CharacterProfileView`) —
  confirm photos appear without visible lazy-load pop-in when scrolling/swiping.
- As a non-PRO user, confirm locked profile photos still show the frosted placeholder
  and are never downloaded (check network requests).
- Simulate a failed image load (e.g. airplane mode mid-scroll) — confirm one retry
  happens and the view doesn't hang or crash.
