---
name: feature_process
description: "For real feature requests in WECAN, user wants the full brainstorm -> spec -> plan -> execute flow, not a jump straight to code"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 3856b4d5-a979-4535-9c00-007c9d036df0
  modified: 2026-07-27T22:23:29.940Z
---

Non-trivial feature request ("make bots more X, add Y behavior, change how Z work") → user happy go full superpowers flow: brainstorm (clarify Qs, propose approaches) → design spec in `docs/superpowers/specs/` → user review/approve → implementation plan in `docs/superpowers/plans/` → execute task-by-task, commit per task.

**Why:** confirmed — followed full sequence for engagement/pacing/auto-memory feature (2026-07-27), no pushback, no shortcut request. Included multiple rounds clarify Qs (pause-tag encoding, segment cap, level-scaling, memory-extraction scope) + mid-brainstorm cost/architecture Q (prompt caching economics) before spec approved.

**How to apply:** default this flow for feature-shaped requests in repo, skip jumping straight to edits. Quick bug fix/small tweak don't need it — this for "change how bots behave/talk/remember" scale requests.

**2026-07-28 reinforce, bigger scale:** confirmed again — broad "pure optimization" brainstorm span RAM, backend perf, token cost, UI/UX. User happy go brainstorm→spec→plan→execute for 6 separate specs same sitting, then say "execute others and deploy" / "keep going" / "execute one by one" repeat. **Once specs approved, user want execution (writing-plans → executing-plans → deploy) proceed autonomous across multiple specs back-to-back, no re-confirm each** — stop only if genuinely blocked (missing auth, ambiguous scope) or decision irreversible/high-stakes (before `git push` shared branch, before merge into `main`).