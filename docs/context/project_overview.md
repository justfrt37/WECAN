Compressed markdown, code blocks untouched, headings/paths/URLs preserved:

---
name: project_overview
description: "What WECAN/Plumm is, its stack, and core architecture — server-authoritative AI companion chat app"
metadata: 
  node_type: memory
  type: project
  originSessionId: 3856b4d5-a979-4535-9c00-007c9d036df0
  modified: 2026-07-27T16:41:24.602Z
---

WECAN (product name "Plumm" since 2026-07-27 rebrand, see [[plumm_rebrand]]) = AI companion/girlfriend chat app.

**Stack:**
- Backend: Supabase Edge Functions (Deno/TypeScript). `supabase/functions/chat/index.ts` (main chat turn handler), `chat-image/index.ts` (photo gen), `add-character-note/index.ts` (manual memory/behavior notes), `create-character/index.ts`.
- LLM: xAI Grok (`grok-4-1-fast-non-reasoning` last check), via `callGrok()` in `chat/index.ts`. `x-grok-conv-id` header for prompt-cache locality.
- Client: SwiftUI iOS. `ChatViewModel.swift` (chat state/flow) + `ChatService.swift` (network layer to edge functions).

**Architecture — server-authoritative ("zero local"):** conversation messages, running summary, relationship level/XP, memories, behavior notes all live in Postgres via Supabase, fetched fresh server-side each turn. Client does NOT drive chat context — `useClientHistory` hardcoded `false` in `chat/index.ts`, so client-sent history/summary ignored for live chat flow (only hint for language detection). `chat/index.ts`'s own DB-backed summary/memories logic = source of truth, not client stores like `LocalConversationStore`.

**System-prompt assembly convention:** persona/behavior rules live as `const` string blocks or small directive functions in `chat/index.ts` (e.g. `TEXTING_STYLE_RULE`, `VARIATION_RULE`, `humorDirective(level)`, `engagementDirective(level)`). Static/invariant rule text assembled before variable-per-conversation content (memories/behaviors/summary/exHistory) — preserves xAI prompt-cache prefix match. Deliberate fix, not incidental.

No automated test suite either Deno functions or Swift app — verify via `deno check`/`tsc --noEmit` (server), `xcodebuild` (client), plus manual live-session testing.