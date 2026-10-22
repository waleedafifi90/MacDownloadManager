// Hands matching downloads over to Mac Download Manager through its native messaging
// host. If the host or the app is unavailable, the browser keeps the download.
import { isStream, remember } from './media.js';
import { shouldCapture } from './rules.js';

const HOST = 'com.macdownloadmanager.host';
const RULES_MAX_AGE_MS = 30_000;

let cachedRules = null;
let rulesFetchedAt = 0;

function send(message) {
  return chrome.runtime.sendNativeMessage(HOST, message);
}

/** The app's capture rules, refreshed at most every 30 seconds. */
async function getRules() {
  if (cachedRules && Date.now() - rulesFetchedAt < RULES_MAX_AGE_MS) return cachedRules;
  try {
    const reply = await send({ type: 'hello', extensionVersion: chrome.runtime.getManifest().version });
    if (reply?.type === 'rules') {
      cachedRules = reply.rules;
      rulesFetchedAt = Date.now();
      await reloadIfUpdated(reply.extensionVersion);
    }
  } catch (error) {
    console.warn('Mac Download Manager host is not available:', error.message);
    cachedRules = null;
  }
  return cachedRules;
}

/**
 * The app keeps the extension folder at its own version. When the folder has a different
 * version than the one running, reload from disk to pick it up: once per version, so a
 * copy loaded from another folder doesn't reload over and over.
 */
async function reloadIfUpdated(diskVersion) {
  if (!diskVersion || diskVersion === chrome.runtime.getManifest().version) return;
  const { reloadedFor } = await chrome.storage.local.get('reloadedFor');
  if (reloadedFor === diskVersion) return;
  await chrome.storage.local.set({ reloadedFor: diskVersion });
  chrome.runtime.reload();
}

// Say hello when the browser starts or the extension is installed, so the app knows
// it's connected (its setup window waits for this) and an update is picked up early.
chrome.runtime.onStartup.addListener(() => getRules());
chrome.runtime.onInstalled.addListener(() => getRules());

async function isEnabled() {
  const { enabled = true } = await chrome.storage.local.get('enabled');
  return enabled;
}

async function cookiesFor(url) {
  try {
    const cookies = await chrome.cookies.getAll({ url });
    return cookies.map((c) => `${c.name}=${c.value}`).join('; ');
  } catch {
    return '';
  }
}

/** Sends one link to the app; resolves to true if the app took it. */
async function handOver({ url, filename, size, mime, referrer, source }) {
  const capture = {
    url,
    filename: filename ? filename.split(/[\\/]/).pop() : undefined,
    size: size > 0 ? size : undefined,
    mime: mime || undefined,
    referrer: referrer || undefined,
    cookies: (await cookiesFor(url)) || undefined,
    userAgent: navigator.userAgent,
    source,
  };
  try {
    const reply = await send({ type: 'capture', capture });
    if (!reply?.accepted && reply?.error) console.warn('Not captured:', reply.error);
    return reply?.accepted === true;
  } catch (error) {
    console.warn('Could not reach Mac Download Manager:', error.message);
    return false;
  }
}

// Downloads started in the browser. Chrome waits for suggest() before saving, so the
// decision (and the hand-over) happens before any file is written.
chrome.downloads.onDeterminingFilename.addListener((item, suggest) => {
  (async () => {
    const url = item.finalUrl || item.url;
    const size = item.totalBytes > 0 ? item.totalBytes : item.fileSize;
    if (item.byExtensionId === chrome.runtime.id || !(await isEnabled())) return false;
    const rules = await getRules();
    if (!shouldCapture({ filename: item.filename, url, size }, rules)) return false;
    return handOver({ url, filename: item.filename, size, mime: item.mime, referrer: item.referrer, source: 'download' });
  })()
    .then(async (captured) => {
      if (captured) {
        await chrome.downloads.cancel(item.id);
        await chrome.downloads.erase({ id: item.id });
      }
    })
    .catch((error) => console.error(error))
    .finally(() => suggest());
  return true; // suggest() is called asynchronously
});

// "Download with Mac Download Manager" on links and media.
chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: 'download-link',
    title: 'Download with Mac Download Manager',
    contexts: ['link', 'image', 'video', 'audio'],
  });
});

chrome.contextMenus.onClicked.addListener((info) => {
  const url = info.linkUrl || info.srcUrl;
  if (url) handOver({ url, referrer: info.pageUrl, source: 'menu' });
});

// --- Video and audio on pages -------------------------------------------------------

// Stream links seen per tab, kept in session storage so they survive the service worker
// being stopped.
chrome.webRequest.onHeadersReceived.addListener(
  (details) => {
    if (details.tabId < 0 || details.statusCode >= 400) return;
    const type = details.responseHeaders?.find((h) => h.name.toLowerCase() === 'content-type')?.value || '';
    if (!isStream(details.url, type)) return;
    const key = `media:${details.tabId}`;
    chrome.storage.session.get(key).then((stored) =>
      chrome.storage.session.set({ [key]: remember(stored[key] || [], details.url) }),
    );
  },
  { urls: ['http://*/*', 'https://*/*'], types: ['media', 'xmlhttprequest', 'other'] },
  ['responseHeaders'],
);

chrome.tabs.onUpdated.addListener((tabId, change) => {
  if (change.url) chrome.storage.session.remove(`media:${tabId}`);
});
chrome.tabs.onRemoved.addListener((tabId) => chrome.storage.session.remove(`media:${tabId}`));

// Qualities found per page, so the menu opens instantly the second time.
const formatsCache = new Map();
const FORMATS_MAX_AGE_MS = 10 * 60_000;

async function listFormats(tabId, pageUrl, title) {
  const cached = formatsCache.get(pageUrl);
  if (cached && Date.now() - cached.at < FORMATS_MAX_AGE_MS) return cached.reply;
  if (cached?.pending) return cached.pending;

  const pending = (async () => {
    const key = `media:${tabId}`;
    const mediaUrls = (await chrome.storage.session.get(key))[key] || [];
    const media = {
      pageUrl,
      mediaUrls,
      title,
      cookies: (await cookiesFor(pageUrl)) || undefined,
      referrer: pageUrl,
      userAgent: navigator.userAgent,
    };
    try {
      const reply = await send({ type: 'listFormats', media });
      if (reply?.formats?.length) formatsCache.set(pageUrl, { at: Date.now(), reply });
      else formatsCache.delete(pageUrl);
      return reply;
    } catch (error) {
      formatsCache.delete(pageUrl);
      return { error: `Mac Download Manager is not reachable (${error.message})` };
    }
  })();
  formatsCache.set(pageUrl, { at: 0, pending });
  return pending;
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const tabId = sender.tab?.id ?? -1;
  if (message?.type === 'listFormats' && typeof message.pageUrl === 'string') {
    listFormats(tabId, message.pageUrl, message.title).then(sendResponse);
    return true;
  }
  if (message?.type === 'downloadMedia' && message.media?.option) {
    send({ type: 'downloadMedia', media: message.media })
      .then(sendResponse)
      .catch((error) => sendResponse({ accepted: false, error: error.message }));
    return true;
  }
  return false;
});

// The toolbar button turns automatic capture on and off.
async function showState(enabled) {
  await chrome.action.setBadgeText({ text: enabled ? '' : 'OFF' });
  await chrome.action.setBadgeBackgroundColor({ color: '#888' });
  await chrome.action.setTitle({ title: `Mac Download Manager: capture is ${enabled ? 'on' : 'off'}` });
}

chrome.action.onClicked.addListener(async () => {
  const enabled = !(await isEnabled());
  await chrome.storage.local.set({ enabled });
  await showState(enabled);
});

isEnabled().then(showState);
