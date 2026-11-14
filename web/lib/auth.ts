import { createHash, timingSafeEqual } from 'node:crypto';
import { uploadSecret } from './config';
import { jsonError } from './http';

function digest(value: string): Buffer {
  return createHash('sha256').update(value, 'utf8').digest();
}

/**
 * Checks `Authorization: Bearer <UPLOAD_SECRET>` in constant time.
 * Returns an error response, or null when the request is allowed.
 */
export function requireUploadAuth(request: Request): Response | null {
  const secret = uploadSecret();
  if (!secret) {
    return jsonError(503, 'not_configured', 'The upload service is not configured.');
  }
  const header = request.headers.get('authorization') ?? '';
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  const presented = match ? match[1].trim() : '';
  // Compare fixed-length digests so neither content nor length leaks through timing.
  const ok = timingSafeEqual(digest(presented), digest(secret));
  if (!ok || presented.length === 0) {
    return jsonError(401, 'unauthorized', 'Missing or wrong upload secret.');
  }
  return null;
}
