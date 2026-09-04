Merge `3da8f69` — unverified. Never build/run-checked.

---
name: unverified_merge_2026_07_28
description: "Client-side merge commit 3da8f69 (main+furkan_dev) never build/run-verified — flag before trust client code state"
metadata:
  node_type: memory
  type: project
  originSessionId: 3856b4d5-a979-4535-9c00-007c9d036df0
  modified: 2026-07-27T22:23:08.288Z
---

Merge `3da8f69` ("Merge branch 'furkan_dev' into main", 2026-07-28) resolved 5 conflicted Swift files (`Message.swift`, `PlummApp.swift`, `ChatService.swift`, `ChatViewModel.swift`, `ChatMaintenance.swift`/`ChatView.swift` auto-merged) plus `supabase/functions/chat/index.ts`, by hand — see [[plumm_rebrand]] for each side's contribution.

**None build-verified.** `xcodebuild -list -project Plumm.xcodeproj` hung (~2min+, killed) — likely SPM package resolution (`Package.resolved` present, RevenueCat etc.) hitting network this env lacks reliably. Retried real `xcodebuild build ... -disableAutomaticPackageResolution`, backgrounded — user said drop check ("if it is pushed and merged than drop it i can test myself") before finish — exit status unknown, never confirmed.

**Backend (`supabase/functions/chat/index.ts`) IS verified** — deployed prod (`ohpvhgwjmrfjclnumgnm`, `chat` fn) each step through session, version incremented normal, no deploy errors.

**How to apply:** future session asked build/test/ship iOS client — don't assume `main`/`furkan_dev` compiles now — first real signal either way. If `xcodebuild -list` hangs again, suspect SPM/network resolution before assuming merge broke something; try `-disableAutomaticPackageResolution` or check network/proxy access first.