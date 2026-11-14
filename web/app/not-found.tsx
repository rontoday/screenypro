import type { Metadata } from 'next';

export const metadata: Metadata = {
  title: 'Video unavailable · Comakers',
};

export default function NotFound() {
  return (
    <main className="center">
      <div className="notice">
        <svg className="notice-icon" width="28" height="28" viewBox="0 0 24 24" aria-hidden="true">
          <circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" strokeWidth="1.6" />
          <path d="M12 7.5V12l3 2" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
        </svg>
        <h1 className="notice-title">This video has expired</h1>
        <p className="notice-text">
          The link is no longer available. Shared videos are kept for a limited time. Ask the sender for a new link.
        </p>
      </div>
    </main>
  );
}
