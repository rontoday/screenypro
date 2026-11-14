import { requireUploadAuth } from '@/lib/auth';
import {
  MAX_POSTER_BYTES,
  MAX_VIDEO_BYTES,
  MULTIPART_THRESHOLD_BYTES,
  PART_SIZE_BYTES,
  retentionDays,
} from '@/lib/config';
import { json, jsonError, readJsonObject } from '@/lib/http';
import { newVideoId } from '@/lib/ids';
import { paths, presignUpload, uploadHeaders } from '@/lib/videos';

export const dynamic = 'force-dynamic';

function isSize(value: unknown, max: number): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value > 0 && value <= max;
}

/**
 * Step 1 of an upload. Body: { videoBytes, videoContentType: "video/mp4", posterBytes, posterContentType: "image/jpeg" }.
 * Returns a fresh id and presigned direct-to-storage upload URLs. Nothing is watchable until step 2.
 */
export async function POST(request: Request): Promise<Response> {
  const denied = requireUploadAuth(request);
  if (denied) return denied;

  const body = await readJsonObject(request);
  if (!body) return jsonError(400, 'bad_request', 'Expected a JSON object body.');

  if (body.videoContentType !== 'video/mp4') {
    return jsonError(415, 'unsupported_type', 'Only video/mp4 videos are accepted.');
  }
  if (typeof body.videoBytes === 'number' && body.videoBytes > MAX_VIDEO_BYTES) {
    return jsonError(413, 'too_large', 'The video is larger than 5 GB.');
  }
  if (!isSize(body.videoBytes, MAX_VIDEO_BYTES)) {
    return jsonError(400, 'bad_request', 'videoBytes must be a positive integer.');
  }
  const wantsPoster = body.posterBytes !== undefined && body.posterBytes !== null;
  if (wantsPoster) {
    if (body.posterContentType !== 'image/jpeg') {
      return jsonError(415, 'unsupported_type', 'Only image/jpeg posters are accepted.');
    }
    if (!isSize(body.posterBytes, MAX_POSTER_BYTES)) {
      return jsonError(413, 'too_large', 'The poster must be a JPEG of at most 5 MB.');
    }
  }

  const id = newVideoId();
  const ttlDays = retentionDays();
  const [video, poster] = await Promise.all([
    presignUpload({ pathname: paths.video(id), contentType: 'video/mp4', maxBytes: body.videoBytes, ttlDays }),
    wantsPoster
      ? presignUpload({
          pathname: paths.poster(id),
          contentType: 'image/jpeg',
          maxBytes: body.posterBytes as number,
          ttlDays,
        })
      : Promise.resolve(null),
  ]);

  return json(201, {
    id,
    uploadHeaders: uploadHeaders(video.storeId),
    validUntil: new Date(video.validUntil).toISOString(),
    partSizeBytes: PART_SIZE_BYTES,
    multipartThresholdBytes: MULTIPART_THRESHOLD_BYTES,
    video: { contentType: 'video/mp4', ...video.target },
    poster: poster ? { contentType: 'image/jpeg', ...poster.target } : null,
  });
}
