# ImageCache Disk Eviction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cap `ImageCache`'s disk layer at 1GB with LRU eviction, swept once per session on launch/foreground, per `docs/superpowers/specs/2026-07-27-image-cache-disk-eviction-design.md`.

**Architecture:** One new method `ImageCache.evictIfNeeded()` that enumerates the disk cache directory, sums file sizes, and — only if over the 1GB cap — deletes oldest-accessed files until under an 800MB target. Called from two places in `aiGirlfriendApp.swift`: the existing `.task` block (covers cold launch) and the existing `.onChange(of: scenePhase)` `.active` case (covers foreground). Runs off the main thread via `Task.detached(priority: .background)` so it never blocks UI.

**Tech Stack:** Swift/SwiftUI, `FileManager`. No test target exists in this Xcode project (verified: no `*Tests` target in `aiGirlfriend.xcodeproj`) — verification is `xcodebuild build` (compiles clean) plus manual testing per the spec's own Testing section.

## Global Constraints

- Disk cache cap: 1 GB (`1_000_000_000` bytes).
- Eviction target after a sweep: 80% of cap = 800MB (`800_000_000` bytes) — avoids re-triggering eviction on the very next sweep from a single new write.
- Eviction policy: LRU by `.contentAccessDate`, falling back to `.contentModificationDate` when access date is unavailable.
- PNG format stays unchanged — no compression/quality changes (explicitly decided against in the spec).
- Memory-layer (`NSCache`) `totalCostLimit` stays unchanged — already self-evicting.
- Sweep runs once per session trigger (launch, foreground) — NOT on every write.

---

### Task 1: Add `evictIfNeeded()` to `ImageCache`

**Files:**
- Modify: `aiGirlfriend/Services/ImageCache.swift`

**Interfaces:**
- Consumes: existing `private let diskCacheDir: URL` (already defined in the class).
- Produces: `func evictIfNeeded()` — fire-and-forget, no return value, safe to call from anywhere without `await` (internally dispatches to a background `Task.detached`). Consumed by Task 2.

- [ ] **Step 1: Add the method**

In `aiGirlfriend/Services/ImageCache.swift`, add this method to the `ImageCache` class (after `prefetch`, before the closing `}` of the class):

```swift
    /// Bir seferlik LRU temizliği — disk cache 1GB'ı aşıyorsa en eski
    /// erişilmiş dosyalardan başlayarak %80'e (800MB) inene kadar siler.
    /// Her yazımda DEĞİL, oturum başına bir kez (launch/foreground) çağrılır
    /// — bkz. aiGirlfriendApp.swift. Ana thread'i asla bloklamaz.
    func evictIfNeeded() {
        let diskCacheDir = self.diskCacheDir
        Task.detached(priority: .background) {
            let capBytes = 1_000_000_000   // 1 GB
            let targetBytes = 800_000_000  // 800 MB (cap'in %80'i)
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
            guard let urls = try? fm.contentsOfDirectory(
                at: diskCacheDir,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { return }

            struct Entry { let url: URL; let size: Int; let date: Date }
            var entries: [Entry] = []
            var total = 0
            for url in urls {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                let size = values.fileSize ?? 0
                let date = values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
                entries.append(Entry(url: url, size: size, date: date))
                total += size
            }
            guard total > capBytes else { return }

            entries.sort { $0.date < $1.date }
            var remaining = total
            for entry in entries {
                if remaining <= targetBytes { break }
                try? fm.removeItem(at: entry.url)
                remaining -= entry.size
            }
        }
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild build -project /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **` (or at minimum no errors referencing `ImageCache.swift`).

- [ ] **Step 3: Commit**

```bash
git add aiGirlfriend/Services/ImageCache.swift
git commit -m "perf(client): add LRU disk-cache eviction to ImageCache"
```

---

### Task 2: Call `evictIfNeeded()` on launch and foreground

**Files:**
- Modify: `aiGirlfriend/aiGirlfriendApp.swift`

**Interfaces:**
- Consumes: `ImageCache.shared.evictIfNeeded()` from Task 1.
- Produces: nothing new for later tasks.

- [ ] **Step 1: Call it in the launch `.task` block**

In `aiGirlfriend/aiGirlfriendApp.swift`, find:

```swift
            .task {
                PurchaseService.shared.configure()
                let delegate = NotificationDelegate(store: store)
                notificationDelegate = delegate
                UNUserNotificationCenter.current().delegate = delegate
                // Uygulama bildirime dokunulmadan (ör. ana ekran ikonuyla) açılmış
                // olabilir — zaten teslim edilmiş bildirimlerin mesajını işle.
                delegate.catchUpOnDeliveredNotifications()
                await tokenStore.refresh()
            }
```

Change to:

```swift
            .task {
                PurchaseService.shared.configure()
                let delegate = NotificationDelegate(store: store)
                notificationDelegate = delegate
                UNUserNotificationCenter.current().delegate = delegate
                // Uygulama bildirime dokunulmadan (ör. ana ekran ikonuyla) açılmış
                // olabilir — zaten teslim edilmiş bildirimlerin mesajını işle.
                delegate.catchUpOnDeliveredNotifications()
                await tokenStore.refresh()
                ImageCache.shared.evictIfNeeded()
            }
```

- [ ] **Step 2: Call it on foreground**

Find:

```swift
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                NotificationScheduler.shared.onForeground(characters: store.characters)
                notificationDelegate?.catchUpOnDeliveredNotifications()
                // Picks up newly-added characters (DEV curated creations, etc.)
                // without requiring a reinstall — bkz. CharacterStore.refreshCharacters.
                Task { await store.refreshCharacters() }
            case .background:
                NotificationScheduler.shared.onBackground(characters: store.characters)
            default:
                break
            }
        }
```

Change to:

```swift
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                NotificationScheduler.shared.onForeground(characters: store.characters)
                notificationDelegate?.catchUpOnDeliveredNotifications()
                // Picks up newly-added characters (DEV curated creations, etc.)
                // without requiring a reinstall — bkz. CharacterStore.refreshCharacters.
                Task { await store.refreshCharacters() }
                ImageCache.shared.evictIfNeeded()
            case .background:
                NotificationScheduler.shared.onBackground(characters: store.characters)
            default:
                break
            }
        }
```

(Note: `.active` fires on cold launch too, in addition to the `.task` block — calling `evictIfNeeded()` from both isn't harmful since the method is cheap when under the cap and idempotent, but if it feels redundant the `.task` call could be dropped. Keeping both is deliberate here since `.task` runs once at view-tree construction while `.active` can fire multiple times per session — this guarantees at least one sweep even in edge cases where scenePhase transitions are missed.)

- [ ] **Step 3: Verify it compiles**

Run: `xcodebuild build -project /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add aiGirlfriend/aiGirlfriendApp.swift
git commit -m "perf(client): sweep ImageCache disk eviction on launch and foreground"
```

---

### Task 3: Manual verification

**Files:** none

**Interfaces:**
- Consumes: the finished code from Tasks 1-2.
- Produces: nothing — final task.

- [ ] **Step 1: Confirm normal image loading still works**

Run the app in the simulator (or on device), browse the feed and open a few chats with generated photos. Confirm images still load correctly (memory→disk→network fallback chain unaffected by the new method existing).

- [ ] **Step 2: Confirm eviction actually fires when over cap**

This requires seeding >1GB of cache data, which isn't practical to script from this environment. Suggested manual approach: temporarily lower `capBytes`/`targetBytes` in a local debug build (e.g. to `5_000_000`/`4_000_000`) to a size a few chat photos will exceed, run the app, generate/download several photos, background and reforeground the app (or relaunch), and inspect `Caches/ImageCache/` (via a device file browser or by adding a temporary debug log of directory size) to confirm old files were removed and the directory dropped under the temporary target. Revert the temporary constants afterward — this is a one-off manual verification, not a permanent debug toggle.

- [ ] **Step 3: Report result**

No further commits needed — this task is verification only. If Step 2 shows eviction not firing or firing incorrectly (e.g. deleting recently-accessed files), stop and fix Task 1 before considering this plan complete.
