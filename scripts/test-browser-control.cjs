'use strict';
// Host-side structural guard only; this does not compile ArkTS or test ArkWeb.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const browser = fs.readFileSync('entry/src/main/ets/pages/Browser.ets', 'utf8');
const index = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
assert.match(browser, /export class BrowserControl/);
assert.match(browser, /currentGeneration\(\) !== generation/g);
assert.match(browser, /onPageBegin\(\(event\) => \{\s*this\.loading = true;\s*this\.progress = Math\.max\(this\.progress, 5\);\s*if \(event\?\.url\) \{ this\.currentUrl = event\.url; \}\s*this\.control\.pageBegin\(event\?\.url \|\| ''\);/);
assert.match(browser, /Button\('确认'\)[\s\S]{0,220}?\.onClick\(\(\) => \{ this\.onConfirmPage\(\); \}\)/);
assert.match(browser, /onPageEnd\(\(event\) => \{\s*this\.loading = false;[\s\S]*?this\.control\.pageEnd/);
assert.doesNotMatch(browser, /onPageEnd\(\(event\) => \{[^}]*onConfirmPage/);
assert.match(browser, /aboutToDisappear\(\): void \{ this\.control\.detach\(\); \}/);
assert.match(browser, /private manualNavigation\(\): void \{\s*this\.control\.consumeRebind\(\);\s*this\.onNavigationFailure\(\);\s*this\.control\.navigationChanged\(\);/);
for (const method of ['backward', 'forward', 'refresh']) {
  assert.match(browser, new RegExp('this\\.manualNavigation\\(\\);[\\s\\S]{0,160}?this\\.controller\\.' + method + '\\(\\)'));
}
assert.match(browser, /this\.manualNavigation\(\);\s*this\.currentUrl = target;[\s\S]*?this\.controller\.loadUrl\(target\);/);
assert.match(browser, /private openAuthorized[\s\S]*?this\.control\.navigationChanged\(\);\s*try \{\s*this\.currentUrl = normalized;[\s\S]*?this\.controller\.loadUrl\(normalized\);/);
assert.match(browser, /this\.controller\.getTitle\(\)/);
assert.match(browser, /this\.controller\.getUrl\(\)/);
assert.match(browser, /\.runJavaScript\(BROWSER_OBSERVE_SCRIPT\)/);
assert.match(browser, /this\.controller\.scrollBy\(0, offset\)/);
assert.doesNotMatch(browser, /\.javaScriptProxy\s*\(|document\.querySelector/);
assert.match(index, /control: this\.browserControl/);
console.log('browser control structural checks passed (ArkTS/device unverified)');
