// Run with: node --test App/BrowserExtension/tests/rules.test.mjs
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { extensionOf, isExcludedHost, shouldCapture } from '../chrome/rules.js';

const rules = { enabled: true, extensions: ['zip', 'dmg', 'r0*', 'mp4'], excludedHosts: ['example.org'], minimumSize: 1024 };

test('extension from file names and URLs', () => {
  assert.equal(extensionOf('/Users/me/Downloads/App.DMG'), 'dmg');
  assert.equal(extensionOf('https://x.com/a/file.zip?token=1#top'), 'zip');
  assert.equal(extensionOf('C:\\dl\\movie.r01'), 'r01');
  assert.equal(extensionOf('.hidden'), '');
  assert.equal(extensionOf('README'), '');
});

test('captures matching downloads', () => {
  assert.ok(shouldCapture({ url: 'https://cdn.com/a.zip', size: 5000 }, rules));
  assert.ok(shouldCapture({ url: 'https://cdn.com/download?id=7', filename: '/tmp/Setup.dmg' }, rules));
  assert.ok(shouldCapture({ url: 'https://cdn.com/part.r00' }, rules), 'r0* matches .r00');
});

test('leaves the rest to the browser', () => {
  assert.ok(!shouldCapture({ url: 'https://cdn.com/page.html' }, rules), 'not in the list');
  assert.ok(!shouldCapture({ url: 'https://cdn.com/a.zip', size: 10 }, rules), 'smaller than the minimum');
  assert.ok(!shouldCapture({ url: 'https://dl.example.org/a.zip' }, rules), 'excluded site');
  assert.ok(!shouldCapture({ url: 'blob:https://cdn.com/1234' }, rules), 'blob URL');
  assert.ok(!shouldCapture({ url: 'data:application/zip;base64,AAAA' }, rules), 'data URL');
  assert.ok(!shouldCapture({ url: 'https://cdn.com/a.zip' }, { ...rules, enabled: false }), 'turned off');
  assert.ok(!shouldCapture({ url: 'https://cdn.com/a.zip' }, null), 'app not reachable');
});

test('excluded sites cover subdomains only', () => {
  assert.ok(isExcludedHost('example.org', ['example.org']));
  assert.ok(isExcludedHost('A.Example.org', ['example.org']));
  assert.ok(!isExcludedHost('notexample.org', ['example.org']));
});
