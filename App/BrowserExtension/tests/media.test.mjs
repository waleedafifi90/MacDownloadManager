// Run with: node --test App/BrowserExtension/tests/media.test.mjs
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { isStream, remember } from '../chrome/media.js';

test('recognizes streams by content type or extension', () => {
  assert.ok(isStream('https://cdn.example/live/master.m3u8?token=1', ''));
  assert.ok(isStream('https://cdn.example/manifest.mpd', ''));
  assert.ok(isStream('https://cdn.example/clip', 'video/mp4'));
  assert.ok(isStream('https://cdn.example/playlist', 'application/vnd.apple.mpegurl'));
  assert.ok(isStream('https://cdn.example/song.mp3', ''));
});

test('ignores segments, pages, and YouTube internals', () => {
  assert.ok(!isStream('https://cdn.example/seg-00012.ts', 'video/mp2t'), 'HLS segment');
  assert.ok(!isStream('https://cdn.example/chunk-5.m4s', 'video/iso.segment'), 'DASH segment');
  assert.ok(!isStream('https://cdn.example/index.html', 'text/html'));
  assert.ok(!isStream('https://rr3---sn-abc.googlevideo.com/videoplayback?itag=22', 'video/mp4'), 'YouTube streams');
  assert.ok(!isStream('blob:https://cdn.example/1234', ''));
});

test('remembers the newest unique links', () => {
  let list = [];
  for (const n of [1, 2, 3, 2]) list = remember(list, `u${n}`, 3);
  assert.deepEqual(list, ['u1', 'u3', 'u2']);
  list = remember(list, 'u4', 3);
  assert.deepEqual(list, ['u3', 'u2', 'u4']);
});
