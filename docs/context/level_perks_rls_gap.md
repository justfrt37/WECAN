---
name: level_perks_rls_gap
description: "RESOLVED 2026-08-24 — level_perks/conversation_perk_unlocks now RLS-enabled default-deny, documented as service-role-only"
metadata: 
  node_type: memory
  type: project
  originSessionId: e629eaf0-f125-4152-b223-384935f26ede
  modified: 2026-08-24T17:44:33.143Z
---

Backend for the "Level Perks" feature (`level_perks`, `conversation_perk_unlocks` tables) lives in Supabase project `ohpvhgwjmrfjclnumgnm`. Client/server integration still not started as of this update.

**Resolved 2026-08-24** during a full security review: both tables now have RLS enabled with zero policies (confirmed via `pg_tables`/`pg_policies` — this is Postgres default-deny for `anon`/`authenticated`, only `service_role` bypasses). Added `COMMENT ON TABLE` on both marking them service-role-only/intentional, migration `document_service_role_only_tables`. The original anon-full-CRUD grants described below no longer exist — verify current grants before trusting this note if a lot of time has passed.

**How to apply:** if building the level-perks client feature, these tables are currently unreachable from the client entirely (by design, matches every other app table) — any client feature will need to go through an edge function using the service role, or get real owner-scoped RLS policies added first.
