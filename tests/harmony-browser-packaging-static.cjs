'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const source = path.join(root, 'plugins/dsh-harmony-browser');
const raw = path.join(root, 'entry/src/main/resources/rawfile/tools/harmony-browser');
const files = ['package.json', 'index.js', 'client-relay.js', 'relay.cjs', 'credential-provider.js'];
assert.deepEqual(fs.readdirSync(raw).sort(), [...files].sort());
for (const file of files) {
  assert.deepEqual(fs.readFileSync(path.join(raw, file)), fs.readFileSync(path.join(source, file)), file);
}
const runtime = fs.readFileSync(path.join(root, 'entry/src/main/ets/platform/NativeRuntime.ets'), 'utf8');
// Installing and enabling the plugin is gated by explicit browserAgent=true;
// starting the relay itself still requires an explicit caller.
assert.match(runtime, /\.browserAgent !== true/);
assert.equal((runtime.match(/startBrowserRelay\s*\(/g) || []).length, 1);
console.log('browser resource packaging static checks passed');
