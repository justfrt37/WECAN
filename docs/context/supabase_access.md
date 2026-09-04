Using caveman:compress to shrink this memory file.

**Project ref:** `ohpvhgwjmrfjclnumgnm` (org "AI Girlfriend", region ap-northeast-2). No local `supabase` CLI — use `npx supabase <command>`.

**Auth:** `npx supabase login` fail here (non-TTY), `LegacyLoginMissingTokenError`. Working path: user gen personal access token at Supabase dashboard (Account → Access Tokens), then either paste for `export SUPABASE_ACCESS_TOKEN=...`, or user run `! npx supabase login --token <token>` self via `!` prefix. Once logged in this way, CLI session persist rest of machine's use (confirmed working whole 2026-07-27→28 session, one login).

**Deploy chat function:**
```
npx supabase functions deploy chat --project-ref ohpvhgwjmrfjclnumgnm
```
**Check deployed version/timestamp:**
```
npx supabase functions list --project-ref ohpvhgwjmrfjclnumgnm
```
(Docker-not-running warning on deploy harmless/expected — no local `supabase functions serve` here either, so all edge-function test against prod after deploy, no staging exist.)

**Prefer this CLI over the `deploy_edge_function` MCP tool** once a function exceeds a couple hundred lines (e.g. `chat/index.ts`, ~1600 lines). The MCP tool needs the entire file (+ every relative `../_shared/*.ts` import) retyped as a literal string param — slow, and a single dropped char in a 90KB retype silently breaks the deploy. CLI reads straight off disk, handles relative imports automatically, one shot. Confirmed working 2026-08-26.