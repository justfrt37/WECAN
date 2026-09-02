---
name: merge_conflict_policy
description: "When feature branch conflict main, user want main change kept, build on top not overwrite"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 3856b4d5-a979-4535-9c00-007c9d036df0
  modified: 2026-07-27T22:22:56.632Z
---

Merge feature branch into `main`, conflict from work landed on `main` independent (not touched by feature branch commits) — user's explicit order: "the changes on the main should stay intact we should work on them not over them."

**How to apply:**
- Conflicts in files/regions feature branch never touch (pure branch staleness — main moved forward, unrelated work): take main's side whole (`git checkout --ours` while on main, i.e. HEAD = main during merge).
- Conflicts where BOTH sides make genuinely relevant, complementary changes to same region: merge together, don't pick one side — if one side compliance/safety gate (e.g. main's Review Mode, see [[plumm_rebrand]]), make sure merged result still honor gate (e.g. new romantic/sexual prompt content stay gated behind `!reviewMode`).
- Show user actual conflict content before resolve anything non-trivial, no silent resolve + report after — confirmed by user asking "give me the conflicts" before authorize resolve approach.

**2026-07-28 refinement:** once policy established (not first time), user fine with fully autonomous conflict resolve + after-fact summary, no pause-and-show. Confirmed: user said "merge with main then push to main and sync my branch and main. switch back to my branch afterwards" as one composite instruction, resolved much larger conflict set (5 files, ~40 min work) fully solo using same preserve-main/merge-complementary-changes logic, reported resolve decisions after, got "if it would work than np" — satisfied, no redo/re-explain ask. "Show conflicts first" step matter for NOVEL/first-time situation; once confirmed, treat as standing authorization for future merges in this repo.