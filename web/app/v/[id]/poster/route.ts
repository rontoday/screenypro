import { get } from '@vercel/blob';
import { isValidVideoId } from '@/lib/ids';
import { paths, readLiveMeta } from '@/lib/videos';

export const dynamic = 'force-dynamic';

function notFound(): Response {
  return new Response('Not found', { status: 404, headers: { 'Cache-Control': 'no-store' } });
}

/** Stable poster URL for `<video poster>` and Open Graph previews. Small file, so it streams through here. */
export async function GET(_request: Request, { params }: { params: Promise<{ id: string }> }): Promise<Response> {
  const { id } = await params;
  if (!isValidVideoId(id)) return notFound();
  const meta = await readLiveMeta(id);
  if (!meta || !meta.hasPoster) return notFound();

  const result = await get(paths.poster(id), { access: 'private' });
  if (!result || result.statusCode !== 200 || !result.stream) return notFound();

  return new Response(result.stream, {
    headers: {
      'Content-Type': 'image/jpeg',
      'Content-Length': String(result.blob.size),
      // Browser-only cache: a deleted video must not live on in the shared CDN cache.
      'Cache-Control': 'private, max-age=300',
    },
  });
}
