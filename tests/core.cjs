const test = require('node:test');
const assert = require('node:assert/strict');
const { SSEParser, CompletionBuilder } = require('../.test-build/Stream');
const { Agent } = require('../.test-build/Agent');
const { Tools, safePath } = require('../.test-build/Tools');
const { newSession } = require('../.test-build/Types');

test('SSE handles every split, CRLF, comments, multi-line data and DONE', () => {
  const wire = ': heartbeat\r\n\r\ndata: {"choices":[{"delta":{"content":"你好"}}]}\r\n\r\ndata: [DONE]\r\n\r\n';
  for(let i=0;i<=wire.length;i++) {
    const builder = new CompletionBuilder();
    const parser = new SSEParser(data => builder.accept(data));
    parser.push(wire.slice(0,i)); parser.push(wire.slice(i)); parser.finish();
    assert.equal(builder.result().content,'你好');
  }
  const frames=[]; const p=new SSEParser(data=>frames.push(data));
  p.push('data: first\ndata: second\n\n'); assert.deepEqual(frames,['first\nsecond']);
});
test('stream merges fragmented parallel tool calls and preserves reasoning', () => {
  const b=new CompletionBuilder();
  b.accept(JSON.stringify({choices:[{delta:{reasoning_content:'reason',tool_calls:[{index:1,id:'b',function:{name:'read_file',arguments:'{"pa'}},{index:0,id:'a',function:{name:'list_files',arguments:'{"path":"."}'}}]}}]}));
  b.accept(JSON.stringify({choices:[{delta:{tool_calls:[{index:1,function:{arguments:'th":"x"}'}}]},finish_reason:'tool_calls'}]}));
  b.accept('[DONE]'); const m=b.result();
  assert.equal(m.reasoning_content,'reason'); assert.deepEqual(m.tool_calls.map(x=>x.id),['a','b']);
  assert.equal(m.tool_calls[1].function.arguments,'{"path":"x"}');
});
test('truncated streams, oversized frames, malformed JSON and duplicate ids fail closed', () => {
  assert.throws(()=>new CompletionBuilder().result(),/提前关闭/);
  assert.throws(()=>new SSEParser(()=>{}).push('x'.repeat(2097153)),/超过/);
  assert.throws(()=>new CompletionBuilder().accept('bad'));
  const b=new CompletionBuilder();
  b.accept(JSON.stringify({choices:[{delta:{tool_calls:[0,1].map(index=>({index,id:'dup',function:{name:'read_file',arguments:'{}'}}))}}]}));
  b.accept('[DONE]'); assert.throws(()=>b.result(),/不完整/);
});
test('workspace rejects traversal, absolute, backslash, empty segments and controls', () => {
  for(const path of ['../key','/data','a/../b','C:/key','a\\b','a//b','a/./b','a\u0000b','']) assert.throws(()=>safePath(path));
  assert.equal(safePath('notes/计划.md'),'notes/计划.md'); assert.equal(safePath('.',true),'');
});
function workspace() {
  const files=new Map(); let writes=0;
  return {files,get writes(){return writes;},list:async()=>JSON.stringify([...files.keys()]),read:async p=>files.get(p)??'__HARNESS_FILE_NOT_FOUND__',write:async(p,c)=>{writes++;files.set(p,c);return 'ok';}};
}
test('write approval sees complete before/after, rejection never mutates',async()=>{
  const w=workspace(); w.files.set('x','old'); const tools=new Tools(w);
  const result=await tools.run('write_file','{"path":"x","content":"new"}',async a=>{assert.equal(a.before,'old');assert.equal(a.after,'new');return false;},()=>false);
  assert.match(result,/拒绝/); assert.equal(w.writes,0);
  await tools.run('write_file','{"path":"x","content":"new"}',async()=>true,()=>false);
  assert.equal(w.files.get('x'),'new');
});
test('stop during approval prevents approved write',async()=>{
  const w=workspace(); let stopped=false;
  await assert.rejects(new Tools(w).run('write_file','{"path":"x","content":"new"}',async()=>{stopped=true;return true;},()=>stopped),/停止/);
  assert.equal(w.writes,0);
});
test('read failure must not prompt or overwrite',async()=>{
  const w=workspace(); w.read=async()=>{throw Error('disk error');}; let prompts=0;
  await assert.rejects(new Tools(w).run('write_file','{"path":"x","content":"new"}',async()=>{prompts++;return true;},()=>false));
  assert.equal(prompts,0); assert.equal(w.writes,0);
});
function call(id,name,args){return {id,type:'function',function:{name,arguments:JSON.stringify(args)}};}
test('agent loops with exact tool ids and reasoning passed to subsequent request',async()=>{
  let turns=0; const w=workspace(); const s=newSession();
  const transport={cancel(){},async complete(messages,tools,delta){
    turns++; if(turns===1)return {role:'assistant',content:'',reasoning_content:'reason',tool_calls:[call('one','write_file',{path:'plan.md',content:'计划'})]};
    assert.equal(messages[2].reasoning_content,'reason'); assert.equal(messages[3].tool_call_id,'one');
    return {role:'assistant',content:'完成'};
  }};
  await new Agent(transport,new Tools(w),{changed(){},status(){},approve:async()=>true},3).run(s,'写计划');
  assert.equal(turns,2); assert.equal(w.files.get('plan.md'),'计划'); assert.equal(s.messages.at(-1).content,'完成');
});
test('stop closes every pending tool id without replaying remaining tools',async()=>{
  const w=workspace();const s=newSession();let agent;
  const transport={cancel(){},async complete(){return {role:'assistant',content:'',tool_calls:[call('a','write_file',{path:'a',content:'a'}),call('b','write_file',{path:'b',content:'b'})]};}};
  agent=new Agent(transport,new Tools(w),{changed(){},status(){},approve:async()=>{agent.stop();return true;}},3);
  await assert.rejects(agent.run(s,'go'),/停止/);
  assert.deepEqual(s.messages.filter(m=>m.role==='tool').map(m=>m.tool_call_id),['a','b']); assert.equal(w.writes,0);
});
test('round limit bounds execution and leaves a valid history',async()=>{
  let turns=0;const s=newSession();
  const transport={cancel(){},async complete(){return {role:'assistant',content:'',tool_calls:[call(String(++turns),'list_files',{path:'.'})]};}};
  await assert.rejects(new Agent(transport,new Tools(workspace()),{changed(){},status(){},approve:async()=>true},2).run(s,'go'),/上限/);
  assert.equal(turns,2);assert.equal(s.messages.at(-1).role,'tool');
});
