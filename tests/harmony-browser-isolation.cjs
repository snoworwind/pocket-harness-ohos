'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const browser = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/Browser.ets'), 'utf8');
const index = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/Index.ets'), 'utf8');
test('native browser has its own controller and no DSH page bridge', () => {
  assert.match(browser, /new webview\.WebviewController\(\)/);
  assert.doesNotMatch(browser, /\.javaScriptProxy\s*\(|\.javaScriptOnDocumentStart\s*\(|\.onConsole\s*\(/);
  assert.match(browser, /\.fileAccess\(false\)/);
  assert.match(browser, /\.multiWindowAccess\(false\)/);
});
test('navigation enforces HTTP(S) and UI bridge cannot select a URL', () => {
  assert.match(browser, /protocol === 'http' \|\| protocol === 'https'/);
  assert.match(browser, /\.onLoadIntercept\(/);
  const open = index.match(/if \(op === 'browserOpen'\) \{([\s\S]*?)\} else if \(op === 'browserBounds'\)/);
  assert.ok(open, 'browserOpen branch exists');
  assert.doesNotMatch(open[1], /message\[/);
});
