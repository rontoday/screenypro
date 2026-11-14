import { headers } from 'next/headers';

const NO_STORE = { 'Cache-Control': 'no-store' };

export function json(status: number, body: unknown): Response {
  return Response.json(body, { status, headers: NO_STORE });
}

export function jsonError(status: number, code: string, message: string): Response {
  return json(status, { error: { code, message } });
}

/** Reads a small JSON object body. Returns null for anything else. */
export async function readJsonObject(request: Request, maxBytes = 16 * 1024): Promise<Record<string, unknown> | null> {
  const declared = Number(request.headers.get('content-length') ?? '0');
  if (declared > maxBytes) return null;
  let text: string;
  try {
    text = await request.text();
  } catch {
    return null;
  }
  if (text.length > maxBytes) return null;
  try {
    const value: unknown = JSON.parse(text);
    return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

/**
 * Public base URL for share links: PUBLIC_BASE_URL when set (e.g. https://video.comakers.cz),
 * otherwise the host the request came in on.
 */
export function baseUrlFromRequest(request: Request): string {
  const configured = process.env.PUBLIC_BASE_URL?.replace(/\/+$/, '');
  if (configured) return configured;
  const host = request.headers.get('x-forwarded-host') ?? request.headers.get('host') ?? new URL(request.url).host;
  const proto = request.headers.get('x-forwarded-proto') ?? (host.startsWith('localhost') ? 'http' : 'https');
  return `${proto}://${host}`;
}

/** Same as baseUrlFromRequest, for server components. */
export async function baseUrlFromHeaders(): Promise<string> {
  const configured = process.env.PUBLIC_BASE_URL?.replace(/\/+$/, '');
  if (configured) return configured;
  const h = await headers();
  const host = h.get('x-forwarded-host') ?? h.get('host') ?? 'localhost:3000';
  const proto = h.get('x-forwarded-proto') ?? (host.startsWith('localhost') ? 'http' : 'https');
  return `${proto}://${host}`;
}
