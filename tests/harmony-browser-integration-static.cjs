'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const index = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
const browser = fs.readFileSync('entry/src/main/ets/pages/Browser.ets', 'utf8');
test('native button is the only startup path; ready does not publish credentials', () => {
  assert.equal((index.match(/this\.startBrowserAgent\(\)/g) || []).length, 1);
  assert.match(index, /onStartAgent: \(\) => \{ this\.startBrowserAgent\(\); \}/);
  assert.match(browser, /Button\('启动浏览器 Agent'\)\.onClick/);
  assert.doesNotMatch(index, /BrowserCredentials|credentialVerifier|publisher\.deliverReady/);
  const ready = index.match(/deliverReady: async[\s\S]*?\n      },/)[0];
  assert.match(ready, /epoch !== this\.browserAgentEpoch/);
  assert.match(ready, /!this\.browserActuallyVisible\(\)/);
  assert.doesNotMatch(ready, /credential|write|runJavaScript/i);
  assert.match(browser, /browserAgent 插件/);
});
test('session change, lifecycle and relay closure revoke authorization', () => {
  assert.match(index, /sessionId !== this\.browserSessionId[\s\S]*?stopBrowserAgent\('当前会话已变化/);
  assert.match(index, /onPageHide\(\): void \{ this\.stopBrowserAgent/);
  assert.match(index, /onClosed: \(\): void => \{[\s\S]*?this\.browserConsent\.cancel\(\)/);
  assert.match(index, /运行时修复，浏览器 Agent 已停止/);
  assert.match(index, /运行时重启，浏览器 Agent 已停止/);
  assert.match(index, /浏览器不再可见，浏览器 Agent 已停止/);
});
