// Decides which downloads to hand over to the app. The rules come from the app
// (Options ▸ Browsers) through the native host; see CaptureRules in CaptureProtocol.swift.

/** The extension of a file name or URL path, lowercase, without the dot ("" if none). */
export function extensionOf(name) {
  const base = String(name).split(/[\\/]/).pop().split(/[?#]/)[0];
  const dot = base.lastIndexOf('.');
  return dot > 0 ? base.slice(dot + 1).toLowerCase() : '';
}

/** `r0*` style patterns match a prefix, so split archives (.r00, .r01) are caught. */
export function matchesExtension(ext, patterns) {
  return patterns.some((p) => (p.endsWith('*') ? ext.startsWith(p.slice(0, -1)) : ext === p));
}

/** True for the host itself or any subdomain of an excluded site. */
export function isExcludedHost(host, excluded) {
  host = host.toLowerCase();
  return excluded.some((site) => host === site || host.endsWith('.' + site));
}

/**
 * Should this download go to the app?
 * @param {{filename?: string, url: string, size?: number}} download
 * @param {{enabled: boolean, extensions: string[], excludedHosts: string[], minimumSize: number}} rules
 */
export function shouldCapture(download, rules) {
  if (!rules || !rules.enabled) return false;
  let url;
  try {
    url = new URL(download.url);
  } catch {
    return false;
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return false;
  if (isExcludedHost(url.hostname, rules.excludedHosts)) return false;
  if (download.size > 0 && download.size < rules.minimumSize) return false;
  const ext = extensionOf(download.filename || url.pathname);
  return ext !== '' && matchesExtension(ext, rules.extensions);
}
