---
name: semantic-code-search
description: claude-context MCP is configured for this repo — use it for semantic codebase search instead of blind exploration
metadata: 
  node_type: memory
  type: reference
  originSessionId: cccadc01-0556-4a28-9f8c-1bd9c5f1c455
  modified: 2026-09-02T10:12:00.424Z
---

`claude-context` MCP server is wired up (local scope, in `~/.claude.json` for this project).

- Vector store: Zilliz Cloud serverless (aws-eu-central-1), free tier.
- Embeddings: OpenRouter `openai/text-embedding-3-small` (1536-dim) via OpenAI-compatible base URL.
- Excludes: `.contextignore` at repo root.

**How to use:** after a session restart, the MCP exposes index/search tools (`index_codebase`, `search_code`, `get_indexing_status`, `clear_index`). Query semantically ("where is token level-boost logic") instead of grepping cold. Incremental re-index on changed files only (Merkle diff).

**Status 2026-09-02:** index BUILT + verified. 300 files / 300 chunks in Zilliz, `search_code` returns real results. Collection lives in Zilliz Cloud so it survives session restarts.

**Known gap (2026-09-02):** current index is Swift-only. Backend `.ts` (supabase/functions), `.sql` migrations, and `.md` docs are NOT indexed — semantic queries naming them return only `.swift` hits. 300 chunks ≈ 1/file, so coverage is partial too. `.contextignore` does not exclude those extensions; cause is the index run itself. NOT fixing now — user plans to switch to a local embedding model and rebuild the index themselves later. Until then, use grep/Explore for backend + migrations.

**Gotcha:** npx cache corruption (`Cannot find module 'ajv'`) made the MCP fail with `CONNECTION_CLOSED`. Fix: `rm -rf ~/.npm/_npx/<hash>` then let npx reinstall. Node v25 in use.

**In-session fallback if MCP won't load:** drive the server over stdio directly — script pattern in scratchpad `idx.mjs` / `search.mjs` (spawn `npx -y @zilliz/claude-context-mcp@latest` with the env block from `~/.claude.json`, JSON-RPC initialize → tools/call). Keep the process alive while indexing runs in its background loop; poll `get_indexing_status`.
