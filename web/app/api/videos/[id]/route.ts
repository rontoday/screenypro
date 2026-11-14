import { requireUploadAuth } from '@/lib/auth';
import { json, jsonError } from '@/lib/http';
import { isValidVideoId } from '@/lib/ids';
import { deleteVideo } from '@/lib/videos';

export const dynamic = 'force-dynamic';

/** Deletes all blobs of a video (also of an unfinished upload). 404 when nothing was there. */
export async function DELETE(request: Request, { params }: { params: Promise<{ id: string }> }): Promise<Response> {
  const denied = requireUploadAuth(request);
  if (denied) return denied;

  const { id } = await params;
  if (!isValidVideoId(id)) return jsonError(400, 'bad_request', 'Invalid video id.');

  const deleted = await deleteVideo(id);
  if (deleted === 0) return jsonError(404, 'not_found', 'No video with this id.');
  return json(200, { id, deleted });
}
