'use client';

import { useEffect, useRef, useState } from 'react';

const SPEEDS = [1, 1.25, 1.5, 2] as const;

function label(speed: number): string {
  return `${speed}×`;
}

export default function Player({
  src,
  poster,
  width,
  height,
  children,
}: {
  src: string;
  poster?: string;
  width: number;
  height: number;
  children: React.ReactNode;
}) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const [rate, setRate] = useState(1);

  // Keep the selector in sync when the browser's own controls change the speed.
  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;
    const onRate = () => setRate(video.playbackRate);
    video.addEventListener('ratechange', onRate);
    return () => video.removeEventListener('ratechange', onRate);
  }, []);

  const choose = (speed: number) => {
    const video = videoRef.current;
    if (video) video.playbackRate = speed;
    setRate(speed);
  };

  return (
    <>
      <div className="frame">
        <video
          ref={videoRef}
          src={src}
          poster={poster}
          width={width}
          height={height}
          controls
          playsInline
          preload="metadata"
        />
      </div>
      <div className="info">
        <div className="info-text">{children}</div>
        <div className="speed" role="group" aria-label="Playback speed">
          {SPEEDS.map((speed) => (
            <button
              key={speed}
              type="button"
              className="speed-option"
              aria-pressed={rate === speed}
              onClick={() => choose(speed)}
            >
              {label(speed)}
            </button>
          ))}
        </div>
      </div>
    </>
  );
}
