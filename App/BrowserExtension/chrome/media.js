// Which network responses are video/audio streams worth offering (used by background.js).

const STREAM_TYPES = /^(video\/|audio\/|application\/(x-mpegurl|vnd\.apple\.mpegurl|dash\+xml))/i;
const STREAM_EXTENSIONS = /\.(m3u8|mpd|mp4|m4v|webm|mov|mkv|m4a|mp3|aac|ogg|opus|flac|wav)(\?|#|$)/i;
// Single segments of a stream: the playlist/manifest is what matters, not its pieces.
const SEGMENT_EXTENSIONS = /\.(ts|m4s|cmfv|cmfa|aac\.part)(\?|#|$)/i;
// Sites whose pages yt-dlp reads directly; their raw stream requests are noise.
const PAGE_ONLY_HOSTS = /(^|\.)(googlevideo\.com|youtube\.com|ytimg\.com)$/i;

/**
 * @param {string} url
 * @param {string} contentType - the response's Content-Type, or ''
 */
export function isStream(url, contentType) {
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    return false;
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return false;
  if (PAGE_ONLY_HOSTS.test(parsed.hostname)) return false;
  if (SEGMENT_EXTENSIONS.test(parsed.pathname)) return false;
  return STREAM_TYPES.test(contentType || '') || STREAM_EXTENSIONS.test(parsed.pathname);
}

/** Keeps the newest `limit` unique links, most recent last. */
export function remember(list, url, limit = 20) {
  const next = list.filter((u) => u !== url);
  next.push(url);
  return next.slice(-limit);
}
