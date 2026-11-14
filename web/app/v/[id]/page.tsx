import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { cache } from 'react';
import { formatDate, formatDuration } from '@/lib/format';
import { baseUrlFromHeaders } from '@/lib/http';
import { isValidVideoId } from '@/lib/ids';
import { readLiveMeta, signedVideoUrl } from '@/lib/videos';
import Player from './Player';

export const dynamic = 'force-dynamic';

type Props = { params: Promise<{ id: string }> };

const loadMeta = cache(async (id: string) => (isValidVideoId(id) ? readLiveMeta(id) : null));

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { id } = await params;
  const meta = await loadMeta(id);
  if (!meta) return { title: 'Video unavailable · Comakers' };

  const base = await baseUrlFromHeaders();
  const pageUrl = `${base}/v/${id}`;
  const description = `Video · ${formatDuration(meta.durationSeconds)} · available until ${formatDate(meta.expiresAt)}`;
  // The app renders the poster with its longest side at most 1280 px.
  const scale = Math.min(1, 1280 / Math.max(meta.width, meta.height, 1));
  const images = meta.hasPoster
    ? [
        {
          url: `${base}/v/${id}/poster`,
          width: Math.round(meta.width * scale),
          height: Math.round(meta.height * scale),
          type: 'image/jpeg',
          alt: meta.title,
        },
      ]
    : undefined;
  return {
    title: `${meta.title} · Comakers`,
    description,
    openGraph: {
      type: 'video.other',
      url: pageUrl,
      siteName: 'Comakers',
      title: meta.title,
      description,
      images,
    },
    twitter: {
      card: images ? 'summary_large_image' : 'summary',
      title: meta.title,
      description,
      images: images?.map((i) => i.url),
    },
  };
}

export default async function VideoPage({ params }: Props) {
  const { id } = await params;
  const meta = await loadMeta(id);
  if (!meta) notFound();

  const src = await signedVideoUrl(id);
  const width = meta.width > 0 ? meta.width : 16;
  const height = meta.height > 0 ? meta.height : 9;

  return (
    <main className="viewer" style={{ '--vw': width, '--vh': height } as React.CSSProperties}>
      <Player src={src} poster={meta.hasPoster ? `/v/${id}/poster` : undefined} width={width} height={height}>
        <h1 className="title">{meta.title}</h1>
        <p className="meta">
          <span>{formatDate(meta.createdAt)}</span>
          <span className="dot" aria-hidden="true">·</span>
          <span>{formatDuration(meta.durationSeconds)}</span>
          <span className="dot" aria-hidden="true">·</span>
          <span>Available until {formatDate(meta.expiresAt)}</span>
        </p>
      </Player>
    </main>
  );
}
