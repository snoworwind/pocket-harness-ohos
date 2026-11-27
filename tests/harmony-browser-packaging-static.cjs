'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const source = path.join(root, 'plugins/dsh-harmony-browser');
const raw = path.join(root, 'entry/src/main/resources/rawfile/tools/harmony-browser');
const files = ['package.json', 'index.js', 'observe.js', 'policy.js', 'audit.js', 'launch.js', 'client-relay.js', 'relay.cjs', 'credential-provider.js'];
assert.deepEqual(fs.readdirSync(raw).sort(), [...files].sort());
for (const file of files) {
  assert.deepEqual(fs.readFileSync(path.join(raw, file)), fs.readFileSync(path.join(source, file)), file);
}
const runtime = fs.readFileSync(path.join(root, 'entry/src/main/ets/platform/NativeRuntime.ets'), 'utf8');
// Explicit false disables registration; native checks still guard the relay.
assert.match(runtime, /\.browserAgent === false/);
assert.equal((runtime.match(/startBrowserRelay\s*\(/g) || []).length, 1);
console.log('browser resource packaging static checks passed');
