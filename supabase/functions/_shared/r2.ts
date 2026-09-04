// supabase/functions/_shared/r2.ts

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

export async function uploadToR2(key: string, bytes: Uint8Array, contentType: string): Promise<string> {
  const res = await client.fetch(objectUrl(key), {
    method: "PUT",
    body: bytes as BodyInit,
    headers: { "content-type": contentType },
  });
  if (!res.ok) throw new Error(`R2 upload failed (${res.status}): ${await res.text()}`);
  return `${PUBLIC_BASE}/${key}`;
}

export async function deleteFromR2(key: string): Promise<{ error: string | null }> {
  const res = await client.fetch(objectUrl(key), { method: "DELETE" });
  if (!res.ok && res.status !== 404) return { error: `${res.status}: ${await res.text()}` };
  return { error: null };
}

export async function signedR2Url(key: string, expiresInSeconds = 3600): Promise<string> {
  const url = new URL(objectUrl(key));
  url.searchParams.set("X-Amz-Expires", String(expiresInSeconds));
  const signed = await client.sign(new Request(url, { method: "GET" }), { aws: { signQuery: true } });
  return signed.url;
}
