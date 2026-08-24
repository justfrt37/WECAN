# plumm-cdn

Read-only Cloudflare Worker that serves R2 bucket `plumm` over
`https://plumm-cdn.plumm-cdn-worker.workers.dev`. Exists because R2's default
public domain (`*.r2.dev`) is blocked in Turkey — this gives images/audio a
different, unblocked domain to load from. Uses a native R2 bucket binding, no
credentials in code, and R2 egress through Workers is free.

Backend reads/writes still go straight to R2 via `supabase/functions/_shared/r2.ts`
(S3-compatible API, unrelated to this Worker). This Worker is only the public
GET path that `R2_PUBLIC_BASE` (a Supabase secret) points at.

## Deploy

```bash
cd cloudflare/plumm-cdn
npx wrangler login   # one-time browser auth
npx wrangler deploy
```

## Custom domain (not yet set up)

Ideally this would live at `cdn.plummai.com` instead of the `workers.dev`
URL. Blocked for now: Workers custom domains require the domain's
nameservers to point at Cloudflare, and Wix (the registrar) hard-locks
nameserver changes on domains registered through them — no dashboard option,
no API override. Options to unblock: open a Wix support ticket asking them
to unlock it, or transfer the domain to a registrar that allows NS control
(e.g. Namecheap accepts incoming transfers from Wix).

Once the domain's zone is active on Cloudflare:
1. Cloudflare dashboard → Workers & Pages → `plumm-cdn` → Settings →
   Domains & Routes → Add Custom Domain → `cdn.plummai.com`
2. Update the Supabase secret: `R2_PUBLIC_BASE=https://cdn.plummai.com`
3. Re-run a URL backfill on existing DB rows (same pattern as the
   `workers.dev` backfill — see git history on this file's introduction).
