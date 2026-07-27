# ImageCache — Disk Cache Eviction

Scope: `aiGirlfriend/Services/ImageCache.swift`. Part of the client RAM/perf
optimization pass.

## Problem

`ImageCache` has two layers: an `NSCache` memory layer capped at 256MB
(self-evicting, fine as-is) and a disk layer at `Caches/ImageCache/` with
**no cap and no eviction at all** — every image ever fetched (character
catalog photos, feed photos, and every AI-generated chat photo) accumulates
on disk forever. `insert(_:for:)` writes `image.pngData()` (lossless),
compounding the growth for generated chat photos, which for an active
long-term relationship could be dozens-to-hundreds of images.

## Change

Add a size-capped LRU sweep to the disk layer, keeping PNG format as-is
(explicitly decided: don't trade image quality for this).

- **Cap:** 1 GB total for `Caches/ImageCache/`.
- **Eviction trigger:** one sweep per app session, on launch/foreground —
  not on every write. A single sweep is cheap relative to the 1GB budget;
  per-write directory scans would be wasted overhead for no real benefit
  given growth within one session is small relative to the cap.
- **Eviction policy:** on sweep, if total directory size exceeds the cap,
  list files sorted by `.contentAccessDate` (fall back to
  `.contentModificationDate` if access date unavailable — not all
  filesystems update it), delete oldest-accessed first until under a
  target (suggest 80% of cap, i.e. 800MB, to avoid re-triggering eviction
  on the very next sweep from a single new large write).
- **Implementation shape:** new `ImageCache.evictIfNeeded()` static/instance
  method, called once from app startup (`aiGirlfriendApp.swift` launch path
  or `SplashView.task`, wherever other one-time startup work already lives)
  and from `scenePhase == .active` transition (foreground). Runs on a
  background `Task.detached(priority: .background)` — must never block UI.

## Explicitly out of scope

- Switching to JPEG / lossy compression — decided against, PNG stays.
- Per-write eviction checks.
- Memory-layer (`NSCache`) changes — already self-evicting via
  `totalCostLimit`.

## Testing

No automated tests for this file currently. Verify manually: seed the disk
cache past 1GB (e.g. temporarily lower the cap for a test build, or
generate/download enough chat photos), relaunch/foreground the app, confirm
oldest files are removed and total directory size drops under the target.
Confirm images still load correctly (memory→disk→network fallback chain
unaffected) after eviction removes their disk copy.
