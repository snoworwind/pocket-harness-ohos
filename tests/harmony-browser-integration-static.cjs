'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const index = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
const browser = fs.readFileSync('entry/src/main/ets/pages/Browser.ets', 'utf8');
const client = fs.readFileSync('entry/src/main/resources/rawfile/tools/harmony-terminal/client.js', 'utf8');

test('native control and a same-UID launch request may start the browser; credentials stay private', () => {
  assert.ok((index.match(/this\.startBrowserAgent\(\)/g) || []).length >= 2);
  assert.match(index, /onStartAgent: \(\) => \{ this\.startBrowserAgent\(\); \}/);
  assert.match(browser, /Button\(this\.agentConnected \? '断开 Agent' : '连接 Agent'\)/);
  assert.doesNotMatch(index, /BrowserCredentials|credentialVerifier|publisher\.deliverReady/);
  const ready = index.match(/deliverReady: async[\s\S]*?\n      },/)[0];
  assert.match(ready, /epoch !== this\.browserAgentEpoch/);
  assert.match(ready, /!this\.browserAvailable\(\)/);
  assert.doesNotMatch(ready, /credential|write|runJavaScript/i);
});

test('a launch request is validated and never reveals the sidebar by itself', () => {
  const launch = index.match(/private pollBrowserLaunch\(\): void \{[\s\S]*?\n  \}/)[0];
  assert.match(launch, /request\['version'\] !== 1/);
  assert.match(launch, /lstatSync\(file\)/);
  assert.match(launch, /isSymbolicLink\(\)/);
  assert.match(launch, /size > 1024/);
  assert.match(launch, /!this\.browserHostForeground/);
  assert.match(launch, /browserLaunchSession === this\.browserSessionId/);
  assert.doesNotMatch(launch, /browserVisible = true/);
  // The page-side helper only remembers the request. It selects the existing
  // tab after the user has opened the right sidebar, never by expanding it.
  const helper = client.match(/window\.__dshOpenAgentBrowser = function \(sessionId\) \{[\s\S]*?\n        \};/)[0];
  assert.doesNotMatch(helper, /openTabIn|open\(\)|aria-label="打开侧边栏"/);
  assert.match(client, /querySelector\('\[aria-label="收起右侧边栏"\]'\)/);
});

test('session change, lifecycle and relay closure revoke authorization', () => {
  assert.match(index, /sessionId !== this\.browserSessionId[\s\S]*?stopBrowserAgent\('当前会话已变化/);
  assert.match(index, /onPageHide\(\): void \{ this\.browserHostForeground = false;[\s\S]*?this\.stopBrowserAgent/);
  assert.match(index, /onClosed: \(\): void => \{[\s\S]*?this\.browserConsent\.cancel\(\)/);
  assert.match(index, /运行时修复，浏览器 Agent 已停止/);
  assert.match(index, /运行时重启，浏览器 Agent 已停止/);
});
