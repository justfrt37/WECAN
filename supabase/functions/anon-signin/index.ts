// supabase/functions/anon-signin/index.ts
//
// Scoped bypass for Supabase's captcha protection on anonymous sign-in ONLY.
// Captcha (Attack Protection > CAPTCHA) stays ON project-wide — GoTrue
// rejects unauthenticated /auth/v1/signup calls (the anon-key ones the app
// used to make directly) with captcha_failed. Confirmed empirically
// (2026-08-26): the SAME signup call made with the service_role key instead
// of the anon key returns 200 — GoTrue only enforces captcha for public/
// anon-key callers, not privileged service_role callers. So this function
// calls signup server-side with service_role and hands the resulting session
// back to the client. Web's own client-side anon-key signup flow is
// untouched and still captcha-gated.
//
// This reopens the exact abuse vector captcha was turned on to close
// (unlimited free anonymous-user creation), so a per-IP rate limit is
// enforced here instead — tighter than Supabase's own default anon-signup
// limit (30/hr, see auth rate-limits dashboard).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

const MAX_PER_IP_PER_HOUR = 8;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const ip = req.headers.get("x-forwarded-for")?.split(",")[0].trim() ?? "unknown";

    const since = new Date(Date.now() - 3_600_000).toISOString();
    const { count } = await db
      .from("anon_signin_log")
      .select("id", { count: "exact", head: true })
      .eq("ip", ip)
      .gte("created_at", since);
    if ((count ?? 0) >= MAX_PER_IP_PER_HOUR) {
      return json({ error: "rate_limited" }, 429);
    }

    const resp = await fetch(`${SUPABASE_URL}/auth/v1/signup`, {
      method: "POST",
      headers: {
        apikey: SERVICE_ROLE,
        Authorization: `Bearer ${SERVICE_ROLE}`,
        "Content-Type": "application/json",
      },
      body: "{}",
    });
    const data = await resp.json();
    if (!resp.ok) return json(data, resp.status);

    await db.from("anon_signin_log").insert({ ip });

    return json(data);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
