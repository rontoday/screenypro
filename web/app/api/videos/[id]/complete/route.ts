import { setTtl } from '@vercel/blob';
import { requireUploadAuth } from '@/lib/auth';
import { MAX_POSTER_BYTES, MAX_TITLE_LENGTH, MAX_VIDEO_BYTES, retentionDays } from '@/lib/config';
import { baseUrlFromRequest, json, jsonError, readJsonObject } from '@/lib/http';
import { isValidVideoId } from '@/lib/ids';
import { type VideoMeta, headOrNull, paths, writeMeta } from '@/lib/videos';

export const dynamic = 'force-dynamic';

function cleanTitle(value: unknown): string {
  const raw = typeof value === 'string' ? value : '';
  // Drop control characters, collapse whitespace.
  const title = raw.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim();
  return (title || 'Untitled video').slice(0, MAX_TITLE_LENGTH);
}

function nonNegative(value: unknown, max: number): number | null {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= max ? value : null;
}

/**
 * Step 2 of an upload, after the bytes are in storage. Body: { title, durationSeconds, width, height }.
 * Checks the uploaded blobs and writes meta.json. Only now does /v/<id> work.
 */
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }): Promise<Response> {
  const denied = requireUploadAuth(request);
  if (denied) return denied;

  const { id } = await params;
  if (!isValidVideoId(id)) return jsonError(400, 'bad_request', 'Invalid video id.');

  const body = await readJsonObject(request);
  if (!body) return jsonError(400, 'bad_request', 'Expected a JSON object body.');
  const durationSeconds = nonNegative(body.durationSeconds, 7 * 24 * 3600);
  const width = nonNegative(body.width, 16384);
  const height = nonNegative(body.height, 16384);
  if (durationSeconds === null || width === null || height === null) {
    return jsonError(400, 'bad_request', 'durationSeconds, width and height must be non-negative numbers.');
  }

  const [video, poster] = await Promise.all([headOrNull(paths.video(id)), headOrNull(paths.poster(id))]);
  if (!video) return jsonError(409, 'video_missing', 'The video file was not uploaded.');
  if (video.contentType !== 'video/mp4' || video.size <= 0 || video.size > MAX_VIDEO_BYTES) {
    return jsonError(422, 'invalid_video', 'The uploaded video is not a valid MP4 within 5 GB.');
  }
  const hasPoster = !!poster && poster.contentType === 'image/jpeg' && poster.size <= MAX_POSTER_BYTES;

  const ttlDays = retentionDays();
  // The presigned upload already set the TTL; repair it if the store ever ignored it.
  const missingTtl = [video, hasPoster ? poster : null].filter((b) => b && !b.expiresAt).map((b) => b!.url);
  if (missingTtl.length > 0) await setTtl(missingTtl, { ttlDays });

  const now = new Date();
  const meta: VideoMeta = {
    version: 1,
    id,
    title: cleanTitle(body.title),
    createdAt: now.toISOString(),
    expiresAt: new Date(now.getTime() + ttlDays * 24 * 3600 * 1000).toISOString(),
    durationSeconds: Math.round(durationSeconds * 1000) / 1000,
    width: Math.round(width),
    height: Math.round(height),
    videoBytes: video.size,
    hasPoster,
  };
  await writeMeta(meta, ttlDays);

  return json(200, {
    id,
    shareUrl: `${baseUrlFromRequest(request)}/v/${id}`,
    expiresAt: meta.expiresAt,
  });
}
