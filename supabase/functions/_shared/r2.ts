// supabase/functions/_shared/r2.ts
//
// Cloudflare R2 client (S3-compatible) — replaces Supabase Storage as the
// upload target for every edge function. The website (plummai-web) already
// serves character images from R2 (`R2_PUBLIC_BASE`, a public `r2.dev`
// domain); the app's own generation paths were still writing to Supabase
// Storage buckets, so newly-generated content never showed up through the
// same CDN. All new uploads go through here instead.
//
// One bucket (`R2_BUCKET`) holds everything, split by key prefix:
// `curated/`, `generated/`, `voices/`, `lora-bootstrap/` are public
// (served straight off `R2_PUBLIC_BASE`); `user-photos/` stays private,
// served only via short-lived presigned GET URLs (mirrors the old
// Supabase `createSignedUrl` privacy model — never put user-photo keys on
// the public base URL).

import { AwsClient } from "https://esm.sh/aws4fetch@1.0.20?target=deno";

const ACCOUNT_ID = Deno.env.get("R2_ACCOUNT_ID")!;
const ACCESS_KEY_ID = Deno.env.get("R2_ACCESS_KEY_ID")!;
const SECRET_ACCESS_KEY = Deno.env.get("R2_SECRET_ACCESS_KEY")!;
const BUCKET = Deno.env.get("R2_BUCKET")!;
const PUBLIC_BASE = (Deno.env.get("R2_PUBLIC_BASE") ?? "").replace(/\/$/, "");

const ENDPOINT = `https://${ACCOUNT_ID}.r2.cloudflarestorage.com`;

const client = new AwsClient({
  accessKeyId: ACCESS_KEY_ID,
  secretAccessKey: SECRET_ACCESS_KEY,
  service: "s3",
  region: "auto",
});

function objectUrl(key: string): string {
  return `${ENDPOINT}/${BUCKET}/${key}`;
}

/// Uploads bytes to R2 and returns the permanent public URL
/// (`R2_PUBLIC_BASE/key`). Use for anything meant to be publicly
/// servable (character photos, voice notes, generated images).
export async function uploadToR2(key: string, bytes: Uint8Array, contentType: string): Promise<string> {
  const res = await client.fetch(objectUrl(key), {
    method: "PUT",
    body: bytes as BodyInit,
    headers: { "content-type": contentType },
  });
  if (!res.ok) throw new Error(`R2 upload failed (${res.status}): ${await res.text()}`);
  return `${PUBLIC_BASE}/${key}`;
}

/// Deletes an object from R2. Best-effort — callers should log, not throw,
/// on failure (mirrors the old Supabase Storage `.remove()` call sites).
export async function deleteFromR2(key: string): Promise<{ error: string | null }> {
  const res = await client.fetch(objectUrl(key), { method: "DELETE" });
  if (!res.ok && res.status !== 404) return { error: `${res.status}: ${await res.text()}` };
  return { error: null };
}

/// Presigned, time-limited GET URL for a private key (never served off
/// `R2_PUBLIC_BASE`). Direct replacement for
/// `db.storage.from(bucket).createSignedUrl(path, expiresIn)`.
export async function signedR2Url(key: string, expiresInSeconds = 3600): Promise<string> {
  const url = new URL(objectUrl(key));
  url.searchParams.set("X-Amz-Expires", String(expiresInSeconds));
  const signed = await client.sign(new Request(url, { method: "GET" }), { aws: { signQuery: true } });
  return signed.url;
}
