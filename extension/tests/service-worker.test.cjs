const { test }=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const EXT='abcdefghijklmnopabcdefghijklmnop';
function worker() {
  const data={settings:{enabled:true,allowedSenders:['alice']}};let listener,installed;const events=[],injected=[];
  const emptyEvent={addListener() {}};
  const chrome={runtime:{id:EXT,getURL:p=>`chrome-extension://${EXT}/${p}`,onMessage:{addListener:fn=>{listener=fn;}},onInstalled:{addListener:fn=>{installed=fn;}},onStartup:emptyEvent,getManifest:()=>JSON.parse(fs.readFileSync(path.join(__dirname,'..','manifest.json'),'utf8')),
    connectNative:()=>{throw new Error('Native host unavailable in boundary test');}},
    storage:{local:{get:async keys=>{keys=Array.isArray(keys)?keys:[keys];return Object.fromEntries(keys.map(k=>[k,structuredClone(data[k])]))},set:async obj=>Object.assign(data,structuredClone(obj)),remove:async keys=>{for(const key of keys)delete data[key];}},onChanged:emptyEvent},
    alarms:{create(){},onAlarm:emptyEvent},
    tabs:{query:async q=>(assert.ok(q.url.every(u=>u.includes('instagram.com'))),[{id:7}]),onCreated:emptyEvent,onRemoved:emptyEvent,onUpdated:emptyEvent},scripting:{executeScript:async o=>{injected.push(o);}}};
  const context=vm.createContext({chrome,URL,setTimeout,clearTimeout,setInterval(){},console,crypto:require('node:crypto').webcrypto});
  context.importScripts=(...files)=>files.forEach(file=>vm.runInContext(fs.readFileSync(path.join(__dirname,'..',file),'utf8'),context,{filename:file}));
  vm.runInContext(fs.readFileSync(path.join(__dirname,'..','service-worker.js'),'utf8'),context,{filename:'service-worker.js'});
  return {data,installed:r=>installed(r),injected,send:(message,sender)=>new Promise(resolve=>{const result=listener(message,sender,resolve);assert.equal(result,true);})};
}
function sender(extra={}) {return {id:EXT,url:'https://www.instagram.com/direct/inbox/',frameId:0,tab:{id:10},...extra};}
const observation=()=>({type:'pet.observation',event:{version:1,type:'dm',eventId:'ig:boundary',sender:'alice',text:'Message',threadUrl:'https://www.instagram.com/direct/t/123/',kind:'inbox-preview',observedAt:new Date().toISOString()}});
test('worker rejects foreign extension ID, origin, scheme, and subframe',async()=>{
  const w=worker();for(const value of [{id:'foreign'},{url:'https://evil.example/direct/inbox/'},{url:'http://www.instagram.com/direct/inbox/'},{frameId:1}])assert.equal((await w.send(observation(),sender(value))).ok,false);
  assert.equal(w.data.pending,undefined);
});
test('Instagram content cannot invoke demo or extension management actions',async()=>{
  const w=worker();for(const type of ['pet.test','pet.clear','pet.ping','pet.status','pet.config.sync','pet.settings.save'])assert.equal((await w.send({type},sender())).ok,false);
});
test('root Instagram page may report metadata but may not submit observations',async()=>{
  const w=worker(),s=sender({url:'https://www.instagram.com/'});
  assert.equal((await w.send({type:'pet.diagnostics',info:{state:'open-dm-page',page:'other',text:'must not persist'}},s)).ok,true);
  assert.equal(w.data.diagnostics['10'].text,undefined);
  assert.equal((await w.send(observation(),s)).ok,false);
});
test('exact extension options URL is accepted even when opened as a tab',async()=>{
  const w=worker(),ui=sender({url:`chrome-extension://${EXT}/options.html`});
  assert.equal((await w.send({type:'pet.status'},ui)).ok,true);
  assert.equal((await w.send({type:'pet.status'},sender({url:`chrome-extension://${EXT}/unknown.html` }))).ok,false);
});
test('valid direct-page event is persisted before acknowledgement; kind test stays forbidden',async()=>{
  const w=worker();assert.equal((await w.send(observation(),sender())).ok,true);
  assert.equal(w.data.pending[0].event.sender,'alice');
  assert.equal((await w.send({...observation(),event:{...observation().event,eventId:'test:forged',kind:'test'}},sender())).ok,false);
});
test('extension reload re-injects content scripts into open Instagram tabs, but not on Chrome update',async()=>{
  const w=worker();w.installed({reason:'chrome_update'});await new Promise(r=>setTimeout(r,10));assert.equal(w.injected.length,0);
  w.installed({reason:'update'});await new Promise(r=>setTimeout(r,10));
  assert.deepEqual(w.injected.map(o=>[o.target.tabId,o.files.join()]),[[7,'common.js,detector.js,content.js']]);
});
test('read marks only come from the thread tab itself and are forwarded to the host',async()=>{
  const w=worker(),thread='https://www.instagram.com/direct/t/123/';
  for(const [threadUrl,url] of [[thread,'https://www.instagram.com/direct/inbox/'],[thread,'https://www.instagram.com/direct/t/999/'],['https://evil.example/direct/t/123/',thread]])
    assert.match((await w.send({type:'pet.read',threadUrl},sender({url}))).error,/own thread page/);
  // Validation passed: the request reaches the (unavailable) native host.
  assert.match((await w.send({type:'pet.read',threadUrl:thread},sender({url:thread}))).error,/Native host unavailable/);
});
