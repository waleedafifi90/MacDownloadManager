// Shows "Download this video" over video and audio players, with the qualities the app
// finds (through yt-dlp) in a menu. Runs in every page and frame.
(() => {
  if (window.__macDownloadManagerOverlay) return;
  window.__macDownloadManagerOverlay = true;

  const HIDE_DELAY_MS = 1200;
  const MIN_VIDEO = { width: 180, height: 100 };

  // One closed shadow root, so the page's CSS can't touch our UI (and ours can't touch it).
  const host = document.createElement('div');
  host.style.cssText = 'all: initial; position: fixed; top: 0; left: 0; width: 0; height: 0; z-index: 2147483647;';
  const root = host.attachShadow({ mode: 'closed' });
  root.innerHTML = `
    <style>
      :host { all: initial; }
      .wrap { position: fixed; display: none; flex-direction: column; align-items: flex-end;
              font: 13px/1.3 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
      .wrap.visible { display: flex; }
      /* One blue pill: the download button, then the × that hides it, split by a thin line. */
      .row { display: flex; align-items: stretch; border-radius: 7px; overflow: hidden;
             background: rgba(26, 115, 242, 0.94); box-shadow: 0 2px 10px rgba(0,0,0,.35); }
      button.main { display: flex; align-items: center; gap: 6px; padding: 6px 11px; border: 0;
                    background: transparent; color: #fff; font: inherit; font-weight: 600; cursor: pointer; }
      button.close { display: flex; align-items: center; justify-content: center; padding: 0 9px; border: 0;
                     border-left: 1px solid rgba(255, 255, 255, 0.35); background: transparent; color: #fff;
                     cursor: pointer; }
      button.main:hover, button.close:hover { background: rgb(18, 98, 214); }
      .menu { display: none; margin-top: 6px; min-width: 240px; max-width: 340px; max-height: 320px; overflow: auto;
              background: rgba(30, 30, 32, 0.97); color: #eee; border-radius: 9px; padding: 6px;
              box-shadow: 0 6px 24px rgba(0,0,0,.45); }
      .menu.open { display: block; }
      .title { padding: 4px 8px 8px; color: #aaa; font-size: 12px; white-space: nowrap; overflow: hidden;
               text-overflow: ellipsis; border-bottom: 1px solid rgba(255,255,255,.08); margin-bottom: 4px; }
      .option { display: block; width: 100%; text-align: left; padding: 7px 8px; border: 0; border-radius: 6px;
                background: transparent; color: inherit; font: inherit; cursor: pointer; }
      .option:hover { background: rgba(26, 115, 242, 0.9); color: #fff; }
      .note { padding: 8px; color: #bbb; }
      .error { padding: 8px; color: #ff8a80; }
    </style>
    <div class="wrap">
      <div class="row">
        <button class="main" type="button">
          <svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor"
            d="M7 1h2v8.6l3.3-3.3 1.4 1.4L8 13.4 2.3 7.7l1.4-1.4L7 9.6zM2 14h12v2H2z"/></svg>
          <span class="label">Download this video</span>
        </button>
        <button class="close" type="button" title="Hide for this video" aria-label="Hide">
          <svg width="11" height="11" viewBox="0 0 10 10" aria-hidden="true"><path stroke="currentColor"
            stroke-width="1.8" stroke-linecap="round" d="M2 2l6 6M8 2l-6 6"/></svg>
        </button>
      </div>
      <div class="menu"></div>
    </div>`;
  const wrap = root.querySelector('.wrap');
  const button = root.querySelector('button.main');
  const label = root.querySelector('.label');
  const menu = root.querySelector('.menu');
  const closeButton = root.querySelector('button.close');

  let target = null;        // the media element the button belongs to
  let hideTimer = null;
  let menuOpen = false;
  const listings = new Map(); // page URL -> Promise of the app's reply
  const dismissed = new WeakSet(); // players the user closed the button on (until reload)

  function attach() {
    const parent = document.fullscreenElement && document.fullscreenElement.tagName !== 'VIDEO'
      ? document.fullscreenElement : document.documentElement;
    if (host.parentNode !== parent) parent.appendChild(host);
  }

  function isCandidate(el) {
    const r = el.getBoundingClientRect();
    if (el.tagName === 'AUDIO') return el.controls && r.width >= 120 && r.height > 0;
    return r.width >= MIN_VIDEO.width && r.height >= MIN_VIDEO.height;
  }

  function mediaUnder(x, y) {
    for (const el of document.querySelectorAll('video, audio')) {
      if (!isCandidate(el)) continue;
      const r = el.getBoundingClientRect();
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) return el;
    }
    return null;
  }

  function place() {
    if (!target) return;
    const r = target.getBoundingClientRect();
    wrap.style.top = `${Math.max(r.top + 10, 6)}px`;
    wrap.style.right = `${Math.max(window.innerWidth - r.right + 10, 6)}px`;
  }

  function show(el) {
    if (dismissed.has(el)) return;
    clearTimeout(hideTimer);
    if (target !== el) {
      target = el;
      label.textContent = el.tagName === 'AUDIO' ? 'Download this audio' : 'Download this video';
      closeMenu();
    }
    attach();
    place();
    wrap.classList.add('visible');
    // Start looking up the qualities now, so the menu is ready when clicked.
    listing();
  }

  function scheduleHide() {
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => {
      if (menuOpen) return;
      wrap.classList.remove('visible');
      target = null;
    }, HIDE_DELAY_MS);
  }

  function listing() {
    const pageUrl = location.href;
    if (!listings.has(pageUrl)) {
      const request = chrome.runtime
        .sendMessage({ type: 'listFormats', pageUrl, title: document.title })
        .catch((error) => ({ error: error.message }));
      listings.set(pageUrl, request);
      // Don't keep failures: the app may be installed or started later.
      request.then((reply) => { if (!reply?.formats?.length) listings.delete(pageUrl); });
    }
    return listings.get(pageUrl);
  }

  function closeMenu() {
    menuOpen = false;
    menu.classList.remove('open');
    menu.replaceChildren();
  }

  function note(text, className = 'note') {
    const div = document.createElement('div');
    div.className = className;
    div.textContent = text;
    return div;
  }

  async function openMenu() {
    menuOpen = true;
    menu.classList.add('open');
    menu.replaceChildren(note('Finding qualities…'));
    const reply = await listing();
    if (!menuOpen) return;
    if (!reply?.formats?.length) {
      menu.replaceChildren(note(reply?.error || 'No downloadable video found on this page.', 'error'));
      return;
    }
    const title = note(reply.media?.title || document.title, 'title');
    const options = reply.formats.map((option) => {
      const item = document.createElement('button');
      item.type = 'button';
      item.className = 'option';
      item.textContent = option.label;
      item.addEventListener('click', () => choose(reply.media, option));
      return item;
    });
    menu.replaceChildren(title, ...options);
  }

  async function choose(media, option) {
    menu.replaceChildren(note('Sending to Mac Download Manager…'));
    const reply = await chrome.runtime
      .sendMessage({ type: 'downloadMedia', media: { ...media, option } })
      .catch((error) => ({ accepted: false, error: error.message }));
    menu.replaceChildren(reply?.accepted
      ? note('Sent to Mac Download Manager ✓')
      : note(reply?.error || 'Could not reach Mac Download Manager.', 'error'));
    setTimeout(() => { closeMenu(); scheduleHide(); }, 1600);
  }

  button.addEventListener('click', (event) => {
    event.stopPropagation();
    event.preventDefault();
    menuOpen ? closeMenu() : openMenu();
  });
  closeButton.addEventListener('click', (event) => {
    event.stopPropagation();
    event.preventDefault();
    if (target) dismissed.add(target);
    closeMenu();
    clearTimeout(hideTimer);
    wrap.classList.remove('visible');
    target = null;
  });
  wrap.addEventListener('mouseenter', () => clearTimeout(hideTimer));
  wrap.addEventListener('mouseleave', scheduleHide);

  // Players are often covered by the site's own controls, so check the pointer position
  // against every player instead of relying on the element under the mouse.
  let pending = false;
  document.addEventListener('mousemove', (event) => {
    if (pending) return;
    pending = true;
    requestAnimationFrame(() => {
      pending = false;
      const el = mediaUnder(event.clientX, event.clientY);
      if (el && !dismissed.has(el)) show(el);
      else if (target && !menuOpen) scheduleHide();
    });
  }, { passive: true, capture: true });

  document.addEventListener('click', (event) => {
    if (menuOpen && !event.composedPath().includes(host)) { closeMenu(); scheduleHide(); }
  }, true);
  window.addEventListener('scroll', place, { passive: true, capture: true });
  window.addEventListener('resize', place, { passive: true });
  document.addEventListener('fullscreenchange', () => { attach(); place(); });
})();
