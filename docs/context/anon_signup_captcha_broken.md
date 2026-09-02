---
name: anon-signup-captcha-broken
description: "RESOLVED 2026-08-26 — anon sign-in routed through anon-signin edge function to bypass captcha without disabling it project-wide"
metadata: 
  node_type: memory
  type: project
  originSessionId: f58e1c38-4fd2-40c2-86cd-93c0ea508cb6
---

Was: Supabase Auth's captcha protection (Dashboard → Authentication → Attack Protection) rejected `/auth/v1/signup` with `captcha_failed` for anon-key callers, blocking every fresh iOS install since 2026-08-18 (`SupabaseAuth.signInAnonymously()` had no way to exempt itself).

Fix (commit `5e2bb70`): confirmed empirically that GoTrue only enforces captcha for anon-key callers — the identical `/auth/v1/signup` call authenticated with the **service_role** key returns 200. New edge function `supabase/functions/anon-signin` makes that call server-side and returns the session to the client; `SupabaseAuth.signInAnonymously()` now hits `/functions/v1/anon-signin` instead of `/auth/v1/signup` directly. Captcha stays ON project-wide — web's own client-side anon-key signup flow is untouched.

Since this reopens the abuse vector captcha closed (unlimited free anon-user creation), added a per-IP rate limit (8/hr, tighter than Supabase's own 30/hr default) backed by new `anon_signin_log` table (service-role-only, RLS on, no policies).

Verified live: fully-erased simulator (`xcrun simctl erase`, empty Keychain) reaches onboarding on first launch with no workaround needed; new `is_anonymous=true` user row + matching `anon_signin_log` row confirmed in DB.

**How to apply:** if anon sign-in breaks again, check this edge function's logs first (`npx supabase functions list`/dashboard) before assuming captcha is the culprit again — the direct-signup bypass this documents is now the load-bearing path.
