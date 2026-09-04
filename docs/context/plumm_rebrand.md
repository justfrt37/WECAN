---
name: plumm_rebrand
description: "main branch got a big rebrand + feature push mid-session on 2026-07-27 — directory rename, RevenueCat, review mode"
metadata: 
  node_type: memory
  type: project
  originSessionId: 3856b4d5-a979-4535-9c00-007c9d036df0
  modified: 2026-07-27T22:22:42.277Z
---

2026-07-27: while feature branch (`furkan_dev`) in dev, `main` got commit `16716d2` "feat: Plumm rebrand + RevenueCat paywall, token sync, voice persistence" + `2ebb913` "feat: review mode (kokomombo flag + characters_review), non-flirty chat prompt, chat/UX tweaks".

**Main changes:**
- iOS project dir renamed `aiGirlfriend/` → `Plumm/` (Xcode project too: `aiGirlfriend.xcodeproj` → `Plumm.xcodeproj` — check which exist before assume path).
- RevenueCat paywall added.
- **Review Mode**: App Store compliance feature — `body.reviewMode === true` in `chat/index.ts` swap normal persona/relationship directive for `REVIEW_DIRECTIVE`, strict platonic/non-flirty/non-sexual system prompt. Also gate off `humorDirective`/`engagementDirective` (see `if (!reviewMode) { ... }` in CEVAP-mode assembly). **Any new romantic/sexual/flirty prompt content in `chat/index.ts` must gate behind `!reviewMode`** — hard product requirement (App Store compliance), not style pref.
- `chat-image/index.ts` gained "shot-template tier" curated-photo gen system (character-specific + shared template library via `shot_templates` table), sits between curated-pool check and full from-scratch gen.
- `NotificationScheduler.swift` gained global pending-notification budget system (iOS caps 64 pending local notifications; per-kind budgets, soonest-first eviction) — much more sophisticated than old random-delay "Liked You" scheduling.

**Why matter going forward:** repo can get concurrent work landing on `main` from other session/device while feature branch build — always check `git log main..HEAD` / fetch before assume main where last seen, especially before merge. See [[merge_conflict_policy]] for how conflicts handled when this happen.

**2026-07-28 update — main diverged further, then `furkan_dev` merged into it:**

By time `furkan_dev` (carry 6-spec optimization pass: chat token-cost, backend perf, ImageCache disk eviction, LocalConversationStore in-place updates, Clear Chat selective-keep, failed-send retry) merged into `main`, main had independently added:
- **`ImageCache.swift` full RAM rework**: images downsampled via ImageIO (`kCGImageSourceThumbnailMaxPixelSize`, 1280px) before hit memory, stored as JPEG (not PNG), `NSCache` capped 48MB/60 items (down from 256MB), memory-pressure notification wipe cache, `prefetch` uses bounded 5-concurrent sliding window. **No disk-size cap existed** — furkan_dev's `evictIfNeeded()` (1GB cap, LRU by access date, sweep on launch/foreground) layered on top of main's version instead of reintroduce furkan_dev's old memory-cache tuning.
- **`ChatViewModel.updateCache()`**: main moved actual persistence work onto serial background `DispatchQueue` (`Self.persistQueue`) instead of run sync on MainActor — diff fix for same "expensive full-array-copy on every message" problem furkan_dev's in-place-`LocalConversationStore`-mutation spec targeted. Main's version kept where main touched call site (`sendImageRequest()`, `applyPostReplyEffects()` — also gained `store?.setLevel(...)` for instant profile-cache updates); furkan_dev's `appendMessage`/`updateMessage`/`updateFields`/`refreshDetectedLanguage` API survived everywhere else (send/sendUserVoice/sendUserPhoto/deliverSegments/generatePendingImage's caption/generatePendingVoice/reactToPrivateDownload) since those call sites untouched by main. **Net result: both `updateCache()` (main's queued version) and newer in-place API coexist in `ChatViewModel.swift` — intentional, not leftover mess.**
- **`sendImageRequest()`**: main added server-persisted pending-photo state (`await service.savePhotoMessage(...)`) so unproduced "generate" photo balloon survive app relaunch — main's version kept wholesale here.
- **`REVIEW_DIRECTIVE`/`reviewMode`** in `chat/index.ts`: combined w/ furkan_dev's `fetchDirectiveMemoriesBehaviors` parallel-fetch helper (fetch always run parallel; `reviewMode` just swap which directive string used after).

Merge commit `3da8f69` landed on both `main` and `furkan_dev` (fast-forwarded), pushed to origin. **Merged client-side code never build/run-verified** (`xcodebuild` hung on `-list`, likely SPM package resolution need network; user said drop check, would test self) — see [[unverified_merge_2026_07_28]].