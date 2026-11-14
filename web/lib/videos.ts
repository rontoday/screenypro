import {
  type IssuedSignedToken,
  BlobNotFoundError,
  del,
  get,
  head,
  issueSignedToken,
  list,
  parseStoreIdFromDelegationToken,
  presignUrl,
  put,
} from '@vercel/blob';
import {
  BLOB_API_VERSION,
  BLOB_CDN_MAX_AGE_SECONDS,
  MAX_TITLE_LENGTH,
  UPLOAD_URL_VALIDITY_MS,
  VIEW_URL_VALIDITY_MS,
} from './config';

// Everything about a video lives under v/<id>/: video.mp4, poster.jpg, meta.json.
// meta.json is written last (by the completion step), so a video without it is never watchable.

export const paths = {
  prefix: (id: string) => `v/${id}/`,
  video: (id: string) => `v/${id}/video.mp4`,
  poster: (id: string) => `v/${id}/poster.jpg`,
  meta: (id: string) => `v/${id}/meta.json`,
};

export interface VideoMeta {
  version: 1;
  id: string;
  title: string;
  createdAt: string; // ISO 8601
  expiresAt: string; // ISO 8601
  durationSeconds: number;
  width: number;
  height: number;
  videoBytes: number;
  hasPoster: boolean;
}

export interface PresignedTarget {
  /** Single-request upload: `PUT` the whole body here. */
  putUrl: string;
  /** Multipart upload: `POST` here with `x-mpu-action: create | upload | complete`. */
  multipartUrl: string;
}

/** Headers every direct-to-storage request must carry. */
export function uploadHeaders(storeId: string): Record<string, string> {
  return {
    'x-api-version': BLOB_API_VERSION,
    'x-vercel-blob-store-id': storeId,
    'x-vercel-blob-access': 'private',
  };
}

/**
 * Presigned upload URLs for one pathname. The scope (pathname, content type, max size, TTL)
 * is signed, so the client cannot change it.
 */
export async function presignUpload(opts: {
  pathname: string;
  contentType: 'video/mp4' | 'image/jpeg';
  maxBytes: number;
  ttlDays: number;
}): Promise<{ target: PresignedTarget; storeId: string; validUntil: number }> {
  const validUntil = Date.now() + UPLOAD_URL_VALIDITY_MS;
  const token = await issueSignedToken({
    pathname: opts.pathname,
    operations: ['put'],
    allowedContentTypes: [opts.contentType],
    maximumSizeInBytes: opts.maxBytes,
    validUntil,
  });
  const { presignedUrl } = await presignUrl(token, {
    operation: 'put',
    pathname: opts.pathname,
    access: 'private',
    allowedContentTypes: [opts.contentType],
    maximumSizeInBytes: opts.maxBytes,
    addRandomSuffix: false,
    // A retried single PUT may hit a blob that the first attempt already stored.
    allowOverwrite: true,
    cacheControlMaxAge: BLOB_CDN_MAX_AGE_SECONDS,
    ttlDays: opts.ttlDays,
  });
  const url = new URL(presignedUrl);
  const multipart = new URL(url.toString());
  // Same signed query, multipart endpoint (see @vercel/blob multipart/*.ts: `/mpu?pathname=…`).
  multipart.pathname = url.pathname.replace(/\/$/, '') + '/mpu';
  return {
    target: { putUrl: url.toString(), multipartUrl: multipart.toString() },
    storeId: parseStoreIdFromDelegationToken(token.delegationToken),
    validUntil,
  };
}

// One store-wide read delegation per warm instance; individual URLs are signed locally (HMAC only).
let viewToken: IssuedSignedToken | null = null;

async function getViewToken(): Promise<IssuedSignedToken> {
  const now = Date.now();
  if (viewToken && viewToken.validUntil - now > VIEW_URL_VALIDITY_MS + 60 * 60 * 1000) {
    return viewToken;
  }
  viewToken = await issueSignedToken({
    pathname: '*',
    operations: ['get'],
    validUntil: now + 2 * VIEW_URL_VALIDITY_MS,
  });
  return viewToken;
}

/** A time-limited direct URL to the private video (served by the Blob CDN, supports HTTP Range). */
export async function signedVideoUrl(id: string): Promise<string> {
  const token = await getViewToken();
  const { presignedUrl } = await presignUrl(token, {
    operation: 'get',
    pathname: paths.video(id),
    access: 'private',
    validUntil: Date.now() + VIEW_URL_VALIDITY_MS,
  });
  return presignedUrl;
}

function parseMeta(value: unknown, id: string): VideoMeta | null {
  if (!value || typeof value !== 'object') return null;
  const m = value as Record<string, unknown>;
  const finite = (x: unknown) => typeof x === 'number' && Number.isFinite(x) && x >= 0;
  if (
    m.version !== 1 ||
    m.id !== id ||
    typeof m.title !== 'string' ||
    m.title.length > MAX_TITLE_LENGTH ||
    typeof m.createdAt !== 'string' ||
    typeof m.expiresAt !== 'string' ||
    Number.isNaN(Date.parse(m.createdAt)) ||
    Number.isNaN(Date.parse(m.expiresAt)) ||
    !finite(m.durationSeconds) ||
    !finite(m.width) ||
    !finite(m.height) ||
    !finite(m.videoBytes) ||
    typeof m.hasPoster !== 'boolean'
  ) {
    return null;
  }
  return m as unknown as VideoMeta;
}

/** The video's metadata, or null when it does not exist, is broken or has expired. */
export async function readLiveMeta(id: string): Promise<VideoMeta | null> {
  // useCache: false — a deleted video must disappear at once, not after the CDN cache window.
  const result = await get(paths.meta(id), { access: 'private', useCache: false });
  if (!result || result.statusCode !== 200 || !result.stream) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(await new Response(result.stream).text());
  } catch {
    return null;
  }
  const meta = parseMeta(parsed, id);
  if (!meta) return null;
  if (Date.parse(meta.expiresAt) <= Date.now()) return null;
  return meta;
}

export async function headOrNull(pathname: string) {
  try {
    return await head(pathname);
  } catch (error) {
    if (error instanceof BlobNotFoundError) return null;
    throw error;
  }
}

export async function writeMeta(meta: VideoMeta, ttlDays: number): Promise<void> {
  await put(paths.meta(meta.id), JSON.stringify(meta), {
    access: 'private',
    contentType: 'application/json',
    addRandomSuffix: false,
    allowOverwrite: true,
    cacheControlMaxAge: 60,
    ttlDays,
  });
}

/** Deletes every blob under v/<id>/. Returns how many were deleted. */
export async function deleteVideo(id: string): Promise<number> {
  let deleted = 0;
  let cursor: string | undefined;
  do {
    const page = await list({ prefix: paths.prefix(id), cursor, limit: 1000 });
    if (page.blobs.length > 0) {
      await del(page.blobs.map((b) => b.url));
      deleted += page.blobs.length;
    }
    cursor = page.hasMore ? page.cursor : undefined;
  } while (cursor);
  return deleted;
}
