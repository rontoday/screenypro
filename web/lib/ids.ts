import { randomBytes } from 'node:crypto';

/** 24 URL-safe characters = 144 bits from the CSPRNG. */
export function newVideoId(): string {
  return randomBytes(18).toString('base64url');
}

/** Accepts the ids this server generates (and nothing that could escape `v/<id>/`). */
export function isValidVideoId(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{20,64}$/.test(value);
}
