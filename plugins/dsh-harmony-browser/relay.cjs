'use strict';
/*
Private process bridge, protocol v1 (JSON objects, UTF-8, one LF-terminated
frame; no CR). Run `node --jitless relay.cjs` under ArkTS NativeProcess.
No integration or authorization policy is supplied here.

ArkTS reads stdout: first {type:"ready",version:1,host:"127.0.0.1",port,
credential} (credential is 32 random bytes encoded as 64 lowercase hex).
Deliver that credential and port privately to the trusted Node client, never
in a URL, command line, logs, or a web page. Subsequent stdout frames are
{type:"request",id,sessionId,operation:"open",url} or {type:"request",id,
sessionId,operation:"observe"} or {type:"request",id,sessionId,operation:"scroll",direction:"up"|"down"}. ArkTS must authorize each request before executing it,
and reply on stdin with exactly one {type:"result",id,ok:true,value:string}
or {type:"result",id,ok:false,error:string}. A result is an ACK that the
native command submission has finished. For scroll this does not attest actual
scrolling or network quiet. Do not acknowledge merely scheduling work. stdin EOF, malformed/unexpected/late results or stdout
failure terminate the relay. ArkTS must stop work and reap the process on exit.

Node client connects TCP to the given loopback port and immediately sends
{type:"hello",version:1,credential}; receives {type:"ready",version:1}.
Then sends {type:"request",id,sessionId,operation:"open",url} or {type:"request",id,
sessionId,operation:"observe"} or {type:"request",id,sessionId,operation:"scroll",direction:"up"|"down"}; receives the same result frame as ArkTS sent. IDs are
1-64 ASCII letters/digits/underscore/hyphen, unique for the process lifetime.
No pipelining: a request while one is outstanding gets {type:"error",code:
"busy",id}; it is not dispatched, but its ID is consumed. To cancel an active
request send {type:"cancel",id}; relay exits and closes every connection.
Disconnect or timeout while work is outstanding also permanently closes the
relay: execution is UNKNOWN, not cancelled or failed. An EOF without a result
likewise means UNKNOWN; never automatically retry. An error result is definitive
only because ArkTS promises completion before replying. A successful TCP write
is not proof the peer received the result. After receiving and parsing the actual
result, the client must send {type:"receipt",id}; until then the request stays
active. Once accepted, the relay sends {type:"received",id} and releases it.
Invalid receipt, disconnect, or the 30s deadline closes the relay.
A receipt confirms only client protocol processing, not delivery to a human.
sessionId is 1-128 ASCII letters/digits/underscore/hyphen, an unauthenticated
display label, never an authorization identity. stdout backpressure is fatal.
Process restart alone does not prove
native work stopped: the host must ensure that before starting a replacement.

Limits: request/hello frames 8192 bytes, stdin result frames 131072 bytes,
result value/error UTF-8 <=65536 bytes, URL UTF-8 <=4096 bytes. 10000 unique
IDs per process. Authentication deadline 3s, operation deadline 30s, max 16
connections. Unknown properties/types, malformed JSON/UTF-8, oversized frames,
HTTP and WebSocket handshakes are rejected by closing the socket. The credential
prevents blind local connections, NOT isolation from code running under the same
UID, debuggers, compromised host/client, or a process able to read the secret.
*/
const net = require('node:net');
const crypto = require('node:crypto');
const { TextDecoder } = require('node:util');
const fs = require('node:fs');
const path = require('node:path');

// Publication is deliberately opt-in. Same-UID processes are the trust boundary.
const publishReady = process.argv.slice(2).includes('--publish-ready');
let publication = null, expiryTimer = null, publicationTimer = null;
function sameFile(a, b) { return a.dev === b.dev && a.ino === b.ino; }
function removeOwned(file, stat) {
  try {
    const current = fs.lstatSync(file);
    if (!sameFile(current, stat)) throw Error('publication conflict');
    fs.unlinkSync(file);
  } catch (e) { if (e.code !== 'ENOENT') throw e; }
}
function cleanupPublication() {
  if (!publication) return;
  const p = publication; publication = null;
  let failed = false;
  for (const entry of [p.temp, p.target]) {
    if (entry) try { removeOwned(entry.file, entry.stat); } catch { failed = true; }
  }
  if (failed) throw Error('publication cleanup failed');
}
function publish(port) {
  const home = process.env.DSH_HOME;
  const c = fs.constants;
  if (!home || !path.isAbsolute(home) || path.resolve(home) === '/' ||
      typeof process.getuid !== 'function' || !c.O_NOFOLLOW || !c.O_EXCL || !c.O_NONBLOCK) throw Error('publication unavailable');
  const uid = process.getuid();
  const dir = path.join(path.dirname(path.resolve(home)), 'browser-managed');
  try { fs.mkdirSync(dir, {mode: 0o700}); } catch (e) { if (e.code !== 'EEXIST') throw e; }
  const ds = fs.lstatSync(dir);
  if (!ds.isDirectory() || ds.uid !== uid || (ds.mode & 0o077)) throw Error('unsafe publication directory');
  const target = path.join(dir, 'ready.json');
  const temp = path.join(dir, '.ready-' + crypto.randomBytes(16).toString('hex'));
  const flags = c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_NOFOLLOW;
  publication = {};
  let fd;
  try {
    // Reserve the destination exclusively; even a stale empty reservation blocks restart.
    fd = fs.openSync(target, flags, 0o600);
    const reserved = fs.fstatSync(fd);
    publication.target = {file: target, stat: reserved};
    if (!reserved.isFile() || reserved.uid !== uid || (reserved.mode & 0o177) || reserved.nlink !== 1) throw Error('unsafe reservation');
    fs.closeSync(fd); fd = undefined;
    fd = fs.openSync(temp, flags, 0o600);
    const created = fs.fstatSync(fd);
    publication.temp = {file: temp, stat: created};
    if (!created.isFile() || created.uid !== uid || (created.mode & 0o177) || created.nlink !== 1) throw Error('unsafe temporary file');
    const expiresAt = Date.now() + 300000;
    const data = Buffer.from(JSON.stringify({version:1,host:'127.0.0.1',port,credential:token,expiresAt}));
    let offset = 0;
    while (offset < data.length) { const n = fs.writeSync(fd, data, offset, data.length - offset); if (!n) throw Error('short write'); offset += n; }
    fs.fsyncSync(fd);
    const finished = fs.fstatSync(fd);
    if (!finished.isFile() || finished.uid !== uid || (finished.mode & 0o177) || finished.nlink !== 1 || finished.size !== data.length) throw Error('unsafe temporary file');
    fs.closeSync(fd); fd = undefined;
    if (!sameFile(fs.lstatSync(target), reserved) || !sameFile(fs.lstatSync(temp), created) || !sameFile(fs.lstatSync(dir), ds)) throw Error('publication conflict');
    fs.renameSync(temp, target);
    publication.temp = null;
    publication.target = {file: target, stat: created};
    const published = fs.lstatSync(target);
    if (!sameFile(published, created)) throw Error('publication conflict');
    expiryTimer = setTimeout(() => stop('credentials expired'), Math.max(0, expiresAt - Date.now()));
    publicationTimer = setInterval(() => {
      try {
        const d = fs.lstatSync(dir), f = fs.lstatSync(target);
        if (!sameFile(d, ds) || !d.isDirectory() || d.uid !== uid || (d.mode & 0o077) ||
            !sameFile(f, created) || !f.isFile() || f.uid !== uid || (f.mode & 0o177) || f.nlink !== 1 ||
            f.size !== published.size || f.mtimeMs !== published.mtimeMs || f.ctimeMs !== published.ctimeMs) throw Error();
      } catch { stop('credential publication conflict'); }
    }, 1000);
  } finally { if (fd !== undefined) fs.closeSync(fd); }
}
process.on('exit', () => { try { cleanupPublication(); } catch { process.exitCode = 1; } });
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => stop('terminated'));

const token = crypto.randomBytes(32).toString('hex');
const sockets = new Set();
const ids = new Set();
let active = null, stopped = false;
const exact = (o, keys) => o && typeof o === 'object' && !Array.isArray(o) && Object.keys(o).length === keys.length && keys.every(k => Object.prototype.hasOwnProperty.call(o, k));
const validId = id => typeof id === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(id);
const size = s => Buffer.byteLength(s, 'utf8');
function stop(reason) {
  if (stopped) return;
  stopped = true;
  if (reason) process.stderr.write('relay: ' + reason + '\n');
  if (active) clearTimeout(active.timer);
  if (expiryTimer) clearTimeout(expiryTimer);
  if (publicationTimer) clearInterval(publicationTimer);
  try { cleanupPublication(); } catch { process.stderr.write('relay: publication cleanup failed\n'); }
  for (const s of sockets) s.destroy();
  server.close();
  process.stdin.pause();
  // Do not wait for blocked stdout or a hostile peer.
  process.exitCode = 1;
  setTimeout(() => process.exit(1), 25).unref();
}
function output(obj) {
  if (stopped || !process.stdout.writable) { stop('stdout unavailable; execution unknown'); return false; }
  try { if (!process.stdout.write(JSON.stringify(obj) + '\n')) { stop('stdout backpressure; execution unknown'); return false; } return true; }
  catch { stop('stdout failure; execution unknown'); return false; }
}
process.stdout.on('error', () => stop('stdout failure; execution unknown'));
process.stdin.on('error', () => stop('stdin failure; execution unknown'));
process.stdin.on('end', () => stop('stdin closed; execution unknown'));
function frames(stream, limit, onFrame, bad) {
  let pending = Buffer.alloc(0), failed = false;
  stream.on('data', chunk => {
    if (failed || stopped) return;
    pending = Buffer.concat([pending, chunk]);
    while (true) {
      const i = pending.indexOf(10);
      if (i < 0) { if (pending.length > limit) { failed = true; bad(); } return; }
      if (i === 0 || i > limit) { failed = true; bad(); return; }
      const bytes = pending.subarray(0, i); pending = pending.subarray(i + 1);
      let obj;
      try {
        if (bytes.includes(13)) throw Error();
        obj = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
      } catch { failed = true; bad(); return; }
      if (!onFrame(obj)) { failed = true; return; }
    }
  });
}
frames(process.stdin, 131072, obj => {
  // The native host may ask up to twice whether this call can skip its own
  // confirmation. It never decides that itself: the answer comes from the
  // authenticated client, which reads the calling Session's live permission.
  if (obj?.type === 'policy-check') {
    if (!exact(obj, ['type','id']) || !validId(obj.id) || !active || active.result ||
        active.awaitingPolicy || active.checks >= 2 || active.id !== obj.id) {
      stop('invalid approval check; execution unknown'); return false;
    }
    active.checks += 1;
    active.awaitingPolicy = true;
    const target = active.socket;
    if (target.destroyed || !target.writable) { stop('client disconnected before approval check'); return false; }
    try { target.write(JSON.stringify({ type: 'policy-check', id: obj.id }) + '\n'); }
    catch { stop('approval check delivery failed'); return false; }
    return true;
  }
  if (!active || active.result || active.awaitingPolicy || !validId(obj?.id) || obj.id !== active.id || typeof obj.ok !== 'boolean' ||
      (obj.ok ? !exact(obj, ['type','id','ok','value']) || typeof obj.value !== 'string' || size(obj.value) > 65536 :
        !exact(obj, ['type','id','ok','error']) || typeof obj.error !== 'string' || size(obj.error) > 65536) || obj.type !== 'result') {
    stop('invalid native result; execution unknown'); return false;
  }
  active.result = true;
  if (active.socket.destroyed || !active.socket.writable) { stop('client disconnected after result'); return false; }
  try { active.socket.write(JSON.stringify(obj) + '\n'); }
  catch { stop('client result delivery failed'); return false; }
  return true;
}, () => stop('invalid stdin frame; execution unknown'));
const server = net.createServer(socket => {
  if (stopped || sockets.size >= 16) { socket.destroy(); return; }
  sockets.add(socket);
  socket.setNoDelay(true);
  let authenticated = false;
  const helloTimer = setTimeout(() => socket.destroy(), 3000);
  socket.on('error', () => {});
  socket.on('close', () => {
    clearTimeout(helloTimer); sockets.delete(socket);
    if (active?.socket === socket) stop('client disconnected; execution unknown');
  });
  const send = obj => {
    if (socket.destroyed) return;
    if (socket.writableLength > 131072) { socket.destroy(); return; }
    socket.write(JSON.stringify(obj) + '\n');
  };
  frames(socket, 8192, obj => {
    if (!authenticated) {
      if (!exact(obj, ['type','version','credential']) || obj.type !== 'hello' || obj.version !== 1 ||
          typeof obj.credential !== 'string' || !/^[a-f0-9]{64}$/.test(obj.credential) ||
          !crypto.timingSafeEqual(Buffer.from(obj.credential, 'hex'), Buffer.from(token, 'hex'))) { socket.destroy(); return false; }
      authenticated = true; clearTimeout(helloTimer); send({type:'ready',version:1}); return true;
    }
    if (obj?.type === 'receipt') {
      if (!exact(obj, ['type','id']) || !validId(obj.id) || !active || !active.result || active.socket !== socket || active.id !== obj.id) {
        stop('invalid receipt'); return false;
      }
      try { socket.write(JSON.stringify({type:'received',id:obj.id}) + '\n'); }
      catch { stop('receipt acknowledgement failed; execution unknown'); return false; }
      clearTimeout(active.timer); active = null; return true;
    }
    if (exact(obj, ['type','id','automatic']) && obj.type === 'policy') {
      if (typeof obj.automatic !== 'boolean' || !validId(obj.id) || !active || !active.awaitingPolicy ||
          active.socket !== socket || active.id !== obj.id) {
        stop('invalid approval reply'); return false;
      }
      active.awaitingPolicy = false;
      if (!output({ type: 'policy', id: obj.id, automatic: obj.automatic })) return false;
      return true;
    }
    if (exact(obj, ['type','id']) && obj.type === 'cancel' && validId(obj.id) && active?.socket === socket && active.id === obj.id) {
      stop('client cancelled; execution unknown'); return false;
    }
    let valid = validId(obj?.id) && obj.type === 'request' && typeof obj.sessionId === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(obj.sessionId);
    if (valid && obj.operation === 'observe') valid = exact(obj, ['type','id','sessionId','operation']);
    else if (valid && obj.operation === 'scroll') valid = exact(obj, ['type','id','sessionId','operation','direction']) && (obj.direction === 'up' || obj.direction === 'down');
    else if (valid && obj.operation === 'open') {
      valid = exact(obj, ['type','id','sessionId','operation','url']) && typeof obj.url === 'string' && size(obj.url) <= 4096 && !/[\u0000-\u0020\u007f]/.test(obj.url);
      if (valid) { try { const u = new URL(obj.url); valid = ['http:','https:'].includes(u.protocol) && !u.username && !u.password; } catch { valid = false; } }
    } else valid = false;
    if (!valid || ids.has(obj.id) || ids.size >= 10000) { socket.destroy(); return false; }
    ids.add(obj.id);
    if (active) { send({type:'error',code:'busy',id:obj.id}); return true; }
    active = {id:obj.id,socket,checks:0,awaitingPolicy:false,timer:setTimeout(() => stop('request timed out; execution unknown'), 30000)};
    return output(obj);
  }, () => socket.destroy());
});
server.on('error', () => stop('listener failure'));
server.listen({host:'127.0.0.1',port:0,exclusive:true}, () => {
  const port = server.address().port;
  if (publishReady) {
    try { publish(port); } catch { stop('credential publication failed'); return; }
  }
  output({type:'ready',version:1,host:'127.0.0.1',port,credential:token});
});
// Keep stdin flowing even while no native request is outstanding, so EOF is observed.
process.stdin.resume();
