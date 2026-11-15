const test=require('node:test');const assert=require('node:assert/strict');const vm=require('node:vm');const fs=require('node:fs');const path=require('node:path');
function setup() {
  const handlers=new Map();let resolveStatus;let rejectStatus;let destroyed=0;let requestBody;
  const req={on:(name,fn)=>handlers.set(name,fn),off:name=>handlers.delete(name),destroy:()=>{destroyed++;},requestInStream:(url,options)=>{requestBody={url,options};return new Promise((resolve,reject)=>{resolveStatus=resolve;rejectStatus=reject;});}};
  const exports={};
  const code=fs.readFileSync(path.join(__dirname,'../.test-build/DeepSeek.js'),'utf8');
  vm.runInNewContext(code,{exports,require:name=>{
    if(name==='@kit.NetworkKit')return {http:{createHttp:()=>req,RequestMethod:{POST:'POST'}}};
    if(name==='@kit.ArkTS')return {util:{TextDecoder:{create:()=>{const decoder=new TextDecoder('utf-8');return {decodeToString:(bytes,opts)=>decoder.decode(bytes,opts)};}}}};
    if(name==='../core/Stream')return require('../.test-build/Stream');
    throw Error(name);
  }});
  const transport=new exports.DeepSeek({endpoint:'https://api.deepseek.com/',model:'test-model',thinking:true,maxRounds:12},'fake-key');
  return {transport,get destroyed(){return destroyed;},get body(){return requestBody;},status:code=>resolveStatus(code),fail:()=>rejectStatus(Error('network')),emit:(event,bytes)=>handlers.get(event)?.(bytes),get listeners(){return handlers.size;}};
}
const wire='data: {"choices":[{"delta":{"content":"你好🌿"},"finish_reason":"stop"}]}\r\n\r\ndata: [DONE]\r\n\r\n';
test('native HTTP adapter decodes UTF-8 split at every byte and settles on dataEnd before status',async()=>{
  const bytes=new TextEncoder().encode(wire);
  for(let cut=0;cut<=bytes.length;cut++) {
    const s=setup();const p=s.transport.complete([{role:'user',content:'go'}],[],()=>{});
    s.emit('dataReceive',bytes.slice(0,cut).buffer);s.emit('dataReceive',bytes.slice(cut).buffer);s.emit('dataEnd');s.status(200);
    assert.equal((await p).content,'你好🌿');assert.equal(s.destroyed,1);assert.equal(s.listeners,0);
    assert.equal(s.body.url,'https://api.deepseek.com/chat/completions');
    assert.equal(JSON.parse(s.body.options.extraData).thinking.type,'enabled');
  }
});
test('native HTTP adapter waits for dataEnd when headers arrive first',async()=>{
  const s=setup();const p=s.transport.complete([],[],()=>{});s.status(200);await Promise.resolve();
  s.emit('dataReceive',new TextEncoder().encode(wire).buffer);s.emit('dataEnd');assert.equal((await p).content,'你好🌿');
});
test('HTTP errors never expose response bodies or credentials',async()=>{
  const s=setup();const p=s.transport.complete([],[],()=>{});s.status(401);await Promise.resolve();
  s.emit('dataReceive',new TextEncoder().encode('{"error":"secret fake-key"}').buffer);s.emit('dataEnd');
  await assert.rejects(p,error=>/401/.test(error.message)&&!error.message.includes('fake-key'));assert.equal(s.destroyed,1);
});
test('cancel rejects once and removes handlers; late errors do not change result',async()=>{
  const s=setup();const p=s.transport.complete([],[],()=>{});s.transport.cancel();s.transport.cancel();s.fail();
  await assert.rejects(p,/停止/);assert.equal(s.destroyed,1);assert.equal(s.listeners,0);
});
test('truncated HTTP stream never commits partial response',async()=>{
  const s=setup();const p=s.transport.complete([],[],()=>{});s.status(200);await Promise.resolve();
  s.emit('dataReceive',new TextEncoder().encode('data: {"choices":[{"delta":{"content":"partial"}}]}\n\n').buffer);s.emit('dataEnd');
  await assert.rejects(p,/提前关闭/);assert.equal(s.destroyed,1);
});
test('network errors clean up transport resources',async()=>{
  const s=setup();const p=s.transport.complete([],[],()=>{});s.fail();await assert.rejects(p,/网络/);assert.equal(s.destroyed,1);
});
