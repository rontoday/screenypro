// Server-side settings. Read lazily so a missing env var fails the request, not the build.

export const MAX_VIDEO_BYTES = 5 * 1024 * 1024 * 1024; // 5 GiB
export const MAX_POSTER_BYTES = 5 * 1024 * 1024; // 5 MiB
export const MAX_TITLE_LENGTH = 200;
/** Parts for multipart uploads. Blob storage needs at least 5 MiB per part (except the last). */
export const PART_SIZE_BYTES = 16 * 1024 * 1024;
/** Files bigger than this should use multipart. */
export const MULTIPART_THRESHOLD_BYTES = 32 * 1024 * 1024;
/** How long the presigned upload URLs stay valid. */
export const UPLOAD_URL_VALIDITY_MS = 24 * 60 * 60 * 1000;
/** How long a presigned video URL on the viewer page stays valid. */
export const VIEW_URL_VALIDITY_MS = 12 * 60 * 60 * 1000;
/**
 * CDN cache lifetime of uploaded blobs. Deleting a blob does not purge copies already in the Blob CDN cache,
 * so an old signed URL can stream a deleted video until this runs out. Keep it short.
 */
export const BLOB_CDN_MAX_AGE_SECONDS = 300;
/** Blob HTTP API version spoken by @vercel/blob 2.9 (BLOB_API_VERSION). */
export const BLOB_API_VERSION = '13';

export function retentionDays(): number {
  const raw = process.env.RETENTION_DAYS;
  const n = raw ? Number.parseInt(raw, 10) : 14;
  return Number.isInteger(n) && n >= 1 && n <= 730 ? n : 14;
}

export function uploadSecret(): string | null {
  const s = process.env.UPLOAD_SECRET;
  return s && s.length >= 32 ? s : null;
}
