export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const key = decodeURIComponent(url.pathname.replace(/^\/+/, ""));
    if (!key) return new Response("Not found", { status: 404 });

    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed", { status: 405 });
    }

    // user-photos/ is private (served only via presigned S3 GET from
    // supabase/functions/_shared/r2.ts signedR2Url) — must never be
    // reachable through this public, unauthenticated proxy.
    if (key.startsWith("user-photos/")) {
      return new Response("Not found", { status: 404 });
    }

    const object = await env.PLUMM_BUCKET.get(key);
    if (!object) return new Response("Not found", { status: 404 });

    const headers = new Headers();
    object.writeHttpMetadata(headers);
    headers.set("etag", object.httpEtag);
    headers.set("cache-control", "public, max-age=31536000, immutable");

    if (request.method === "HEAD") {
      return new Response(null, { headers });
    }
    return new Response(object.body, { headers });
  },
};
