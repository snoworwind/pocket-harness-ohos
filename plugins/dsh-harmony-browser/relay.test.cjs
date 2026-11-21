'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const net = require('node:net');
const readline = require('node:readline');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');

function lines(stream) {
  const queue = [], waiters = [];
  let ended = false;
  readline.createInterface({input:stream}).on('line', line => {
    const value = JSON.parse(line); const waiter = waiters.shift();
    if (waiter) waiter(value); else queue.push(value);
  }).on('close', () => { ended = true; while (waiters.length) waiters.shift()(null); });
  return () => queue.length ? Promise.resolve(queue.shift()) : ended ? Promise.resolve(null) : new Promise(resolve => waiters.push(resolve));
}
async function setup(t) {
  const child = spawn(process.execPath, ['--jitless', path.join(__dirname, 'relay.cjs')], {stdio:['pipe','pipe','pipe']});
  child.stderr.resume(); child.stdin.on('error', () => {});
  t.after(() => { child.kill(); });
  const out = lines(child.stdout), ready = await out();
  assert.equal(ready.type, 'ready');
  assert.match(ready.credential, /^[a-f0-9]{64}$/);
  const connect = async (credential = ready.credential) => {
    const sock = net.createConnection({host:'127.0.0.1',port:ready.port});
    sock.on('error', () => {}); t.after(() => sock.destroy());
    const next = lines(sock);
    await new Promise(resolve => sock.once('connect', resolve));
    sock.write(JSON.stringify({type:'hello',version:1,credential})+'\n');
    return {sock,next};
  };
  const send = (socket, obj) => socket.write(JSON.stringify(obj)+'\n');
  const reply = obj => child.stdin.write(JSON.stringify(obj)+'\n');
  return {child,out,connect,send,reply,ready};
}
function closed(sock) { return new Promise(resolve => sock.destroyed ? resolve() : sock.once('close', resolve)); }

function publishedChild(home) {
  const child = spawn(process.execPath, ['--jitless', path.join(__dirname, 'relay.cjs'), '--publish-ready'], {env:{...process.env,DSH_HOME:home},stdio:['pipe','pipe','pipe']});
  child.stdin.on('error', () => {}); child.stderr.resume();
  return {child, out:lines(child.stdout), exit:new Promise(resolve => child.once('exit', resolve))};
}
function temporaryHome(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-test-'));
  t.after(() => fs.rmSync(dir, {recursive:true,force:true}));
  return dir;
}
test('publishes private credentials before ready and removes them on stdin EOF', async t => {
  const dir = temporaryHome(t), r = publishedChild(path.join(dir, 'home'));
  t.after(() => r.child.kill());
  const ready = await r.out(), file = path.join(dir, 'browser-managed', 'ready.json');
  assert.equal(ready.type, 'ready');
  const data = JSON.parse(fs.readFileSync(file, 'utf8'));
  assert.deepEqual(Object.keys(data).sort(), ['credential','expiresAt','host','port','version']);
  assert.equal(data.credential, ready.credential); assert.equal(data.port, ready.port);
  assert.ok(data.expiresAt > Date.now() && data.expiresAt <= Date.now() + 300000);
  assert.equal(fs.statSync(path.dirname(file)).mode & 0o777, 0o700);
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  r.child.stdin.end(); assert.notEqual(await r.exit, 0); assert.equal(fs.existsSync(file), false);
});
test('stale publication and unavailable directory fail closed', async t => {
  const dir = temporaryHome(t), managed = path.join(dir, 'browser-managed');
  fs.mkdirSync(managed, {mode:0o700}); const file = path.join(managed, 'ready.json');
  fs.writeFileSync(file, 'stale', {mode:0o600});
  const r = publishedChild(path.join(dir, 'home')); assert.equal(await r.out(), null); assert.notEqual(await r.exit, 0);
  assert.equal(fs.readFileSync(file, 'utf8'), 'stale');
  fs.unlinkSync(file); fs.chmodSync(managed, 0o755);
  const bad = publishedChild(path.join(dir, 'home')); assert.equal(await bad.out(), null); assert.notEqual(await bad.exit, 0);
});
test('replacement is preserved and trips publication circuit', async t => {
  const dir = temporaryHome(t), r = publishedChild(path.join(dir, 'home'));
  t.after(() => r.child.kill()); await r.out();
  const file = path.join(dir, 'browser-managed', 'ready.json');
  fs.unlinkSync(file); fs.writeFileSync(file, 'replacement', {mode:0o600});
  assert.notEqual(await r.exit, 0); assert.equal(fs.readFileSync(file, 'utf8'), 'replacement');
});

test('authentication, exact frames, concurrency and acknowledgements', async t => {
  const r = await setup(t);
  const bad = await r.connect('0'.repeat(64)); await closed(bad.sock);
  const http = net.createConnection({host:'127.0.0.1',port:r.ready.port}); http.on('error',()=>{});
  await new Promise(resolve => http.once('connect',resolve)); http.write('GET / HTTP/1.1\r\nUpgrade: websocket\r\n\r\n'); await closed(http);
  const a = await r.connect(), b = await r.connect();
  assert.deepEqual(await a.next(), {type:'ready',version:1}); assert.deepEqual(await b.next(), {type:'ready',version:1});
  r.send(a.sock,{type:'request',id:'a',sessionId:'session',operation:'open',url:'https://example.com/'});
  assert.deepEqual(await r.out(),{type:'request',id:'a',sessionId:'session',operation:'open',url:'https://example.com/'});
  r.send(b.sock,{type:'request',id:'b',sessionId:'session',operation:'observe'});
  assert.deepEqual(await b.next(),{type:'error',code:'busy',id:'b'});
  r.reply({type:'result',id:'a',ok:true,value:'done'});
  assert.deepEqual(await a.next(),{type:'result',id:'a',ok:true,value:'done'});
  r.send(a.sock,{type:'receipt',id:'a'});
  assert.deepEqual(await a.next(),{type:'received',id:'a'});
  // A receipt and the next request must be ordered on the same connection.
  r.send(a.sock,{type:'request',id:'c',sessionId:'session',operation:'observe'});
  assert.deepEqual(await r.out(),{type:'request',id:'c',sessionId:'session',operation:'observe'});
  r.reply({type:'result',id:'c',ok:false,error:'denied'});
  assert.deepEqual(await a.next(),{type:'result',id:'c',ok:false,error:'denied'});
  r.send(a.sock,{type:'receipt',id:'c'});
  assert.deepEqual(await a.next(),{type:'received',id:'c'});
  r.send(b.sock,{type:'request',id:'b',sessionId:'session',operation:'observe'}); await closed(b.sock);
});

test('result remains busy until receipt and disconnect trips circuit', async t => {
  const r = await setup(t), a = await r.connect(), b = await r.connect(); await a.next(); await b.next();
  r.send(a.sock,{type:'request',id:'x',sessionId:'s',operation:'observe'}); await r.out();
  r.reply({type:'result',id:'x',ok:true,value:'data'});
  assert.deepEqual(await a.next(),{type:'result',id:'x',ok:true,value:'data'});
  r.send(b.sock,{type:'request',id:'y',sessionId:'s',operation:'observe'});
  assert.deepEqual(await b.next(),{type:'error',code:'busy',id:'y'});
  a.sock.destroy(); await closed(b.sock);
});

test('invalid receipt trips circuit after result', async t => {
  const r = await setup(t), a = await r.connect(), b = await r.connect(); await a.next(); await b.next();
  r.send(a.sock,{type:'request',id:'x',sessionId:'s',operation:'observe'}); await r.out();
  r.reply({type:'result',id:'x',ok:true,value:'data'}); await a.next();
  r.send(b.sock,{type:'receipt',id:'x'}); await Promise.all([closed(a.sock),closed(b.sock)]);
});

test('early receipt and duplicate native result fail closed', async t => {
  for (const duplicate of [false, true]) {
    const r = await setup(t), a = await r.connect(), b = await r.connect(); await a.next(); await b.next();
    r.send(a.sock,{type:'request',id:'x',sessionId:'s',operation:'observe'}); await r.out();
    if (duplicate) {
      r.reply({type:'result',id:'x',ok:true,value:'data'}); await a.next();
      r.reply({type:'result',id:'x',ok:true,value:'data'});
    } else r.send(a.sock,{type:'receipt',id:'x'});
    await Promise.all([closed(a.sock),closed(b.sock)]);
  }
});

test('sessionId is required and restricted', async t => {
  const r = await setup(t);
  for (const sessionId of [undefined, '', 'a'.repeat(129), 'bad space', 'é']) {
    const a = await r.connect(); await a.next();
    r.send(a.sock,{type:'request',id:'x',sessionId,operation:'observe'}); await closed(a.sock);
  }
  const a = await r.connect(); await a.next();
  r.send(a.sock,{type:'request',id:'ok',sessionId:'a'.repeat(128),operation:'observe'});
  assert.equal((await r.out()).sessionId.length,128);
});

test('cancel permanently closes bridge with unknown outcome', async t => {
  const r = await setup(t), a = await r.connect(), b = await r.connect(); await a.next(); await b.next();
  r.send(a.sock,{type:'request',id:'x',sessionId:'session',operation:'observe'}); await r.out();
  r.send(a.sock,{type:'cancel',id:'x'});
  await Promise.all([closed(a.sock),closed(b.sock)]);
  assert.notEqual(await new Promise(resolve => r.child.once('exit', resolve)), 0);
});

test('disconnect during execution trips circuit', async t => {
  const r = await setup(t), a = await r.connect(), b = await r.connect(); await a.next(); await b.next();
  r.send(a.sock,{type:'request',id:'x',sessionId:'session',operation:'observe'}); await r.out();
  a.sock.destroy(); await closed(b.sock);
});

test('forged native result fails closed and scripts are rejected', async t => {
  const r = await setup(t), a = await r.connect(); await a.next();
  r.send(a.sock,{type:'request',id:'bad',operation:'evaluate',script:'1+1'}); await closed(a.sock);
  const b = await r.connect(); await b.next();
  r.send(b.sock,{type:'request',id:'x',sessionId:'session',operation:'observe'}); await r.out();
  r.reply({type:'result',id:'forged',ok:true,value:'x'}); await closed(b.sock);
});

test('frame and URL byte limits reject oversized input', async t => {
  const r = await setup(t), a = await r.connect(); await a.next();
  r.send(a.sock,{type:'request',id:'x',sessionId:'session',operation:'open',url:'https://example.com/'+ 'a'.repeat(4096)}); await closed(a.sock);
  const b = await r.connect(); await b.next(); b.sock.write('x'.repeat(8193)); await closed(b.sock);
});

test('missing receipt times out and trips circuit', {timeout: 40000}, async t => {
  const r = await setup(t), a = await r.connect(), b = await r.connect(); await a.next(); await b.next();
  r.send(a.sock,{type:'request',id:'x',sessionId:'session',operation:'observe'}); await r.out();
  r.reply({type:'result',id:'x',ok:true,value:'data'}); await a.next();
  await Promise.all([closed(a.sock),closed(b.sock)]);
});

 test('scroll exact frames are forwarded and malformed scroll frames rejected', async t => {
  const r = await setup(t);
  for (const extra of [{}, {direction:'left'}, {direction:'up',pixels:1}, {direction:'down',script:'x'}, {direction:1}]) {
    const a = await r.connect(); await a.next();
    r.send(a.sock,{type:'request',id:'bad',sessionId:'s',operation:'scroll',...extra}); await closed(a.sock);
  }
  const a = await r.connect(); await a.next();
  for (const direction of ['up','down']) {
    const id = direction; const frame = {type:'request',id,sessionId:'s',operation:'scroll',direction};
    r.send(a.sock,frame); assert.deepEqual(await r.out(),frame);
    r.reply({type:'result',id,ok:true,value:'submitted'}); await a.next(); r.send(a.sock,{type:'receipt',id});
    assert.deepEqual(await a.next(),{type:'received',id});
  }
});

test('approval checks are relayed to the active client and answers reach the host', async t => {
  const r = await setup(t), a = await r.connect(), b = await r.connect();
  await a.next(); await b.next();
  r.send(a.sock, {type:'request',id:'p1',sessionId:'session-a',operation:'observe'});
  assert.deepEqual(await r.out(), {type:'request',id:'p1',sessionId:'session-a',operation:'observe'});
  r.reply({type:'policy-check',id:'p1'});
  assert.deepEqual(await a.next(), {type:'policy-check',id:'p1'});
  r.send(b.sock, {type:'policy',id:'p1',automatic:true});
  await closed(b.sock);
  assert.notEqual(await new Promise(resolve => r.child.once('exit', resolve)), 0, 'a policy reply from another socket trips the circuit');
});

test('the host receives the trusted answer and the request keeps its slot until receipt', async t => {
  const r = await setup(t), a = await r.connect(); await a.next();
  r.send(a.sock, {type:'request',id:'p2',sessionId:'session-a',operation:'observe'});
  assert.equal((await r.out()).id, 'p2');
  r.reply({type:'policy-check',id:'p2'});
  assert.deepEqual(await a.next(), {type:'policy-check',id:'p2'});
  r.send(a.sock, {type:'policy',id:'p2',automatic:true});
  assert.deepEqual(await r.out(), {type:'policy',id:'p2',automatic:true});
  // A second check is allowed (the native rechecks right before execution).
  r.reply({type:'policy-check',id:'p2'});
  assert.deepEqual(await a.next(), {type:'policy-check',id:'p2'});
  r.send(a.sock, {type:'policy',id:'p2',automatic:false});
  assert.deepEqual(await r.out(), {type:'policy',id:'p2',automatic:false});
  r.reply({type:'result',id:'p2',ok:true,value:'done'});
  assert.deepEqual(await a.next(), {type:'result',id:'p2',ok:true,value:'done'});
  r.send(a.sock, {type:'receipt',id:'p2'});
  assert.deepEqual(await a.next(), {type:'received',id:'p2'});
});

test('bad approval answers and a third check trip the circuit', async t => {
  for (const bad of [{type:'policy',id:'p3',automatic:'yes'}, {type:'policy',id:'other',automatic:true}, {type:'result',id:'p3',ok:true,value:'early'}]) {
    const r = await setup(t), a = await r.connect(); await a.next();
    r.send(a.sock, {type:'request',id:'p3',sessionId:'session-a',operation:'observe'});
    await r.out();
    r.reply({type:'policy-check',id:'p3'});
    await a.next();
    r.send(a.sock, bad);
    await closed(a.sock);
  }
  const r = await setup(t), a = await r.connect(); await a.next();
  r.send(a.sock, {type:'request',id:'p4',sessionId:'session-a',operation:'observe'});
  await r.out();
  for (let i = 0; i < 2; i++) { r.reply({type:'policy-check',id:'p4'}); await a.next(); r.send(a.sock, {type:'policy',id:'p4',automatic:true}); await r.out(); }
  r.reply({type:'policy-check',id:'p4'});
  await closed(a.sock);
});

test('an answer to a check that was never asked fails closed', async t => {
  const r = await setup(t), a = await r.connect(); await a.next();
  r.send(a.sock, {type:'request',id:'p5',sessionId:'session-a',operation:'observe'});
  await r.out();
  r.send(a.sock, {type:'policy',id:'p5',automatic:true});
  await closed(a.sock);
});
