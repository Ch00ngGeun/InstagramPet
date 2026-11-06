const { test } = require('node:test');
const assert = require('node:assert/strict');
const { BridgeQueue, validateEvent, PENDING_TTL } = require('../worker-core.js');
const NOW = Date.parse('2026-11-06T01:00:30Z');
const event = (id = 'ig:123') => ({ version:1,type:'dm',eventId:id,sender:'alice',text:'A new DM',threadUrl:'https://www.instagram.com/direct/t/123/',observedAt:new Date(NOW).toISOString(),kind:'thread-message' });
function fixture(nativeRequest = async e => ({type:'ack',ok:true,eventId:e.eventId})) {
  const data = {settings:{enabled:true,allowedSenders:['alice']}}; let now = NOW;
  const deps = { get: async keys => Object.fromEntries(keys.map(k=>[k,structuredClone(data[k])])), set: async values => Object.assign(data,structuredClone(values)), nativeRequest, now:()=>now };
  return {data, queue:new BridgeQueue(deps), deps, advance:ms=>{now+=ms;} };
}
test('protocol validation rejects URL attacks, stale data and forged test events', () => {
  for (const change of [{threadUrl:'https://evil.example/'},{sender:'bob'},{eventId:'../../bad'},{kind:'test'},{observedAt:'bad'},{text:''},{text:'a'.repeat(2001)}]) assert.throws(()=>validateEvent({...event(),...change},['alice'],false,NOW));
  assert.equal(validateEvent(event(),['alice'],false,NOW).sender,'alice');
});
test('simultaneous tabs deduplicate pending before native delivery', async () => {
  const f=fixture(); await Promise.all([f.queue.enqueue(event()),f.queue.enqueue(event())]); assert.equal(f.data.pending.length,1);
  await f.queue.flush(); assert.equal(f.data.pending.length,0); assert.equal(f.data.seen.length,1);
  assert.equal((await f.queue.enqueue(event())).duplicate,true);
});
test('native failure retains event; worker restart and matching ack remove it', async () => {
  const f=fixture(async()=>{throw new Error('Host not installed');}); await f.queue.enqueue(event()); const first=await f.queue.flush(); assert.equal(first.pending,1); assert.equal(f.data.bridge.state,'error');
  const restarted=new BridgeQueue({...f.deps,nativeRequest:async e=>({type:'ack',ok:true,eventId:e.eventId})}); await restarted.flush(); assert.equal(f.data.pending.length,0);
});
test('wrong acknowledgement never loses pending event', async () => {
  const f=fixture(async()=>({type:'ack',ok:true,eventId:'different'})); await f.queue.enqueue(event()); await f.queue.flush(); assert.equal(f.data.pending.length,1);
});
test('retry expires private message text and removing allowlist drops queued events', async () => {
  const f=fixture(async()=>{throw new Error('offline');}); await f.queue.enqueue(event()); f.advance(PENDING_TTL+1); await f.queue.flush(); assert.equal(f.data.pending.length,0);
  const g=fixture(); await g.queue.enqueue(event()); g.data.settings.allowedSenders=[]; await g.queue.flush(); assert.equal(g.data.pending.length,0);
});
test('bounded queue exposes overflow and preserves newest events', async () => {
  const f=fixture(); for(let i=0;i<102;i++)await f.queue.enqueue(event('ig:'+i)); assert.equal(f.data.pending.length,100); assert.equal(f.data.pending[0].event.eventId,'ig:2'); assert.equal(f.data.lastDrop.reason,'queue-full');
});
test('test demo requires explicit allowTest and does not need a real allowlist', async () => {
  const f=fixture(); f.data.settings.allowedSenders=[];
  await assert.rejects(f.queue.enqueue({...event(),kind:'test'})); await f.queue.enqueue({...event(),kind:'test'},true); assert.equal(f.data.pending.length,1);
});
test('event IDs with trailing newline are rejected', () => {
  assert.throws(()=>validateEvent({...event(),eventId:'ig:123\n'},['alice'],false,NOW));
});
