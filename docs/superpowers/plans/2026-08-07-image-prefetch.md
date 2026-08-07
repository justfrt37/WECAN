# Background Image Prefetch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate visible photo pop-in when scrolling `GalleryView`'s user-photo grid
and swiping/scrolling `CharacterProfileView`'s hero+grid, by prefetching those photos
into the existing `ImageCache` as soon as their URLs are known, and add a single retry
to `CachedImage` for failed network loads.

**Architecture:** No new types. Both views call the existing
`ImageCache.shared.prefetch(_ urls: [URL]) async` (ImageCache.swift:120, already
bounded to 5-concurrent downloads and already skips URLs already cached) at the point
each view learns its photo URLs. `CachedImage` gets one additional retry attempt on its
existing network-fetch step.

**Tech Stack:** Swift, SwiftUI, existing `ImageCache`/`CachedImage` (no new
dependencies).

## Global Constraints

- Do not touch chat UI/logic: `ChatViewModel.swift`, `ChatView.swift`,
  `MessageBubble.swift`, `VoiceMessageBubble.swift`, `VoiceCallView.swift`.
- Do not touch `PurchaseService.swift`'s purchase/subscription logic — only read
  `PurchaseService.shared.isPro` (already an existing read-only property used
  elsewhere in `CharacterProfileView.swift`).
- Locked (non-PRO) gallery photos in `CharacterProfileView` must never be downloaded —
  preserve the existing `idx > 0 && !isPro` gating when building the prefetch URL list.
- No XCTest target exists in this repo. Verification is: project builds via
  `xcodebuild -project Plumm.xcodeproj -scheme Plumm -sdk iphonesimulator build`, plus
  manual simulator checks described per task.

---

### Task 1: `GalleryView` — prefetch user's generated photos after fetch

**Files:**
- Modify: `Plumm/Views/GalleryView.swift:39-41`

**Interfaces:**
- Consumes: `ImageCache.shared.prefetch(_ urls: [URL]) async` (existing,
  ImageCache.swift:120).
- Produces: nothing new consumed by later tasks.

- [ ] **Step 1: Add prefetch call after fetch**

Current code (GalleryView.swift:39-41):

```swift
        .task {
            yourPhotos = (try? await GeneratedPhotoService().fetch(characterId: character.id)) ?? []
        }
```

Change to:

```swift
        .task {
            yourPhotos = (try? await GeneratedPhotoService().fetch(characterId: character.id)) ?? []
            await ImageCache.shared.prefetch(yourPhotos)
        }
```

- [ ] **Step 2: Build check**

Run: `xcodebuild -project Plumm.xcodeproj -scheme Plumm -sdk iphonesimulator build`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Manual verification**

Run the app in the simulator (or `/run` skill if available), open a character that has
generated photos in their gallery (`GalleryView`, "Your Photos" grid), and scroll.
Expected: photos appear immediately as they scroll into view rather than popping in
after a network fetch. (If the test account has zero generated photos, this step can
be confirmed by reading the diff instead — `prefetch` is a no-op on an empty array, so
there's no behavior to regress either way.)

- [ ] **Step 4: Commit**

```bash
git add Plumm/Views/GalleryView.swift
git commit -m "perf: prefetch user's generated photos before gallery grid renders"
```

---

### Task 2: `CharacterProfileView` — prefetch unlocked gallery photos on appear

**Files:**
- Modify: `Plumm/Views/CharacterProfileView.swift`

**Interfaces:**
- Consumes: `ImageCache.shared.prefetch(_ urls: [URL]) async` (existing,
  ImageCache.swift:120); `images: [URL]` (existing computed property,
  CharacterProfileView.swift:57-61); `PurchaseService.shared.isPro` (existing, already
  read elsewhere in this file, e.g. line 126).
- Produces: nothing new consumed by later tasks.

- [ ] **Step 1: Add an `.task` modifier that prefetches unlocked photos**

The view's `body` currently ends its `ZStack`/`NavigationStack` setup around
CharacterProfileView.swift:105-113:

```swift
            .navigationDestination(for: Character.self) { ChatView(character: $0) }
            .toolbar(.hidden, for: .navigationBar)
        }
        // PRO gerektiren her yerde onboarding paywall'ı (alttan fullscreen) açılır.
        .fullScreenCover(isPresented: $showPaywall) { OnboardingPaywallView() }
        .sheet(isPresented: $showLevels) {
            RelationshipLevelsView(currentLevel: userLevel)
        }
    }
```

Add a `.task` modifier alongside the existing `.fullScreenCover`/`.sheet` modifiers
(order among sibling modifiers doesn't matter here — none of them depend on each
other), and a private computed property for the unlocked subset:

```swift
            .navigationDestination(for: Character.self) { ChatView(character: $0) }
            .toolbar(.hidden, for: .navigationBar)
        }
        // PRO gerektiren her yerde onboarding paywall'ı (alttan fullscreen) açılır.
        .fullScreenCover(isPresented: $showPaywall) { OnboardingPaywallView() }
        .sheet(isPresented: $showLevels) {
            RelationshipLevelsView(currentLevel: userLevel)
        }
        .task { await ImageCache.shared.prefetch(unlockedImages) }
    }

    /// `images` filtered to what's actually downloadable — mirrors the per-index
    /// lock check in `hero`/`photosSection` (idx 0 always unlocked, rest require PRO)
    /// so locked photos are never prefetched/downloaded.
    private var unlockedImages: [URL] {
        images.enumerated()
            .filter { idx, _ in idx == 0 || PurchaseService.shared.isPro }
            .map(\.element)
    }
```

- [ ] **Step 2: Build check**

Run: `xcodebuild -project Plumm.xcodeproj -scheme Plumm -sdk iphonesimulator build`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Manual verification**

Run the app in the simulator. As a non-PRO account: open a character's profile with
multiple gallery photos, confirm photos after the first still show the frosted
lock placeholder (not the real image), and check `read_network_requests` (or Xcode's
network debugger) to confirm no request was made for locked photo URLs. As a PRO
account (or by toggling whatever debug flag flips `PurchaseService.shared.isPro` in
this codebase — check `DevTokenTools.swift`/existing dev toggles if unsure), confirm
swiping through the hero carousel shows photos immediately without a network-load
flash.

- [ ] **Step 4: Commit**

```bash
git add Plumm/Views/CharacterProfileView.swift
git commit -m "perf: prefetch unlocked character gallery photos on profile open"
```

---

### Task 3: `CachedImage` — retry once on failed network load

**Files:**
- Modify: `Plumm/Views/CachedImage.swift:45-69`

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing new consumed by later tasks.

- [ ] **Step 1: Add one retry to the network-fetch step**

Current code (CachedImage.swift:60-69):

```swift
        // 3) Ağdan indir (timeout ~20s) + çöz/insert yine ana thread dışında.
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return }
        let img = await Task.detached(priority: .userInitiated) {
            // ImageCache içinde ekran boyutuna KÜÇÜLTÜLÜR (RAM tasarrufu).
            ImageCache.shared.insert(data: data, for: url)
        }.value
        if let img, self.url == url { uiImage = img }
    }
```

Change to:

```swift
        // 3) Ağdan indir (timeout ~20s) + çöz/insert yine ana thread dışında.
        //    Bir kez başarısız olursa (geçici ağ hatası) kısa bir bekleme sonrası
        //    tek bir daha dener — sonsuz döngü yok, hâlâ olmazsa placeholder kalır.
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        var data: Data?
        data = try? await URLSession.shared.data(for: request).0
        if data == nil {
            try? await Task.sleep(nanoseconds: 500_000_000)
            data = try? await URLSession.shared.data(for: request).0
        }
        guard let data else { return }
        let img = await Task.detached(priority: .userInitiated) {
            // ImageCache içinde ekran boyutuna KÜÇÜLTÜLÜR (RAM tasarrufu).
            ImageCache.shared.insert(data: data, for: url)
        }.value
        if let img, self.url == url { uiImage = img }
    }
```

- [ ] **Step 2: Build check**

Run: `xcodebuild -project Plumm.xcodeproj -scheme Plumm -sdk iphonesimulator build`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Manual verification**

Run the app in the simulator. Use the simulator's Network Link Conditioner (or
airplane mode toggled on then off mid-load) while scrolling a photo-heavy screen
(`GalleryView` or `CharacterProfileView`) to force a transient failure. Expected: the
image still loads (via the retry) rather than getting stuck on the placeholder, and
the app doesn't hang or crash during the 500ms retry delay.

- [ ] **Step 4: Commit**

```bash
git add Plumm/Views/CachedImage.swift
git commit -m "fix: retry once on failed image network load instead of giving up"
```
