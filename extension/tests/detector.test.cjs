const { test } = require('node:test');
const assert = require('node:assert/strict');
const { JSDOM } = require('jsdom');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const C = require('../common.js'), D = require('../detector.js');
const NOW = Date.parse('2026-11-06T01:00:30Z');
function fixture(name, url = 'https://www.instagram.com/direct/inbox/') {
  return new JSDOM(readFileSync(path.join(__dirname, 'fixtures', name + '.html'), 'utf8'), { url });
}
const cfg = { allowedSenders: ['alice'], bindings: { 123: 'alice' } };
const snap = (dom, config = cfg) => D.scan(dom.window.document, dom.window.location.href, config);
const tracker = () => new D.Tracker({ warmupMs: 0 });
function append(dom, { id='m3', label='Message from Alice', body='New hello', timestamp='2026-11-06T01:00:29Z' } = {}) {
  const row = dom.window.document.createElement('div'); row.setAttribute('role','row'); if (id) row.setAttribute('data-message-id', id); row.setAttribute('aria-label', label);
  row.innerHTML = `<span dir="auto">${body}</span>${timestamp ? `<time datetime="${timestamp}"></time>` : ''}`;
  dom.window.document.querySelector('#messages').append(row); return row;
}
test('first scan suppresses existing unread inbox and transcript', () => {
  for (const [name,url] of [['inbox','https://www.instagram.com/direct/inbox/'],['thread','https://www.instagram.com/direct/t/123/']]) {
    const t = tracker(); assert.deepEqual(t.observe(snap(fixture(name,url)), ['alice'], NOW), []);
  }
});
test('allowlist defaults empty; username and link validation are exact', () => {
  assert.deepEqual(C.settings().allowedSenders, []); assert.equal(C.username('@ALICE'), 'alice');
  for (const value of ['https://evil.example/direct/t/123/','http://www.instagram.com/direct/t/123/','https://www.instagram.com/direct/t/123/?redirect=evil','https://www.instagram.com:444/direct/t/123/']) assert.equal(C.threadURL(value), null);
});
test('inbox requires changed unread preview and verified identity', () => {
  const dom = fixture('inbox'), t = tracker(); t.observe(snap(dom), ['alice'], NOW);
  const p = dom.window.document.getElementById('preview-123'); p.textContent = 'A new hello';
  const events = t.observe(snap(dom), ['alice'], NOW + 1000); assert.equal(events.length,1); assert.equal(events[0].kind,'inbox-preview'); assert.equal(events[0].sender,'alice');
  assert.deepEqual(t.observe(snap(dom), ['alice'], NOW + 2000), []);
  p.textContent = 'You: my outgoing reply'; assert.deepEqual(t.observe(snap(dom), ['alice'], NOW + 3000), []);
  p.textContent = 'Unknown identity'; assert.deepEqual(t.observe(snap(dom, {allowedSenders:['alice']}), ['alice'], NOW + 4000), []);
});
test('unread badge alone is never treated as new text', () => {
  const dom = fixture('inbox'), t = tracker(), row = dom.window.document.querySelector('a'); row.setAttribute('aria-label','Conversation'); t.observe(snap(dom), ['alice'], NOW);
  row.setAttribute('aria-label','Unread conversation'); assert.deepEqual(t.observe(snap(dom), ['alice'], NOW+1000), []);
});
test('new inbound rows emit once; own outgoing and unallowlisted rows do not', () => {
  const dom = fixture('thread','https://www.instagram.com/direct/t/123/'), t = tracker(); t.observe(snap(dom), ['alice'], NOW);
  append(dom); const first = t.observe(snap(dom), ['alice'], NOW+1000); assert.equal(first.length,1); assert.equal(first[0].text,'New hello');
  assert.deepEqual(t.observe(snap(dom), ['alice'], NOW+2000), []);
  append(dom,{id:'m4',label:'You sent',body:'My message'}); assert.deepEqual(t.observe(snap(dom), ['alice'], NOW+3000), []);
  append(dom,{id:'m5',body:'Not on allowlist'}); assert.deepEqual(t.observe(snap(dom), ['someone.else'], NOW+4000), []);
});
test('body profile mentions do not establish incoming direction or identity', () => {
  const dom = fixture('thread','https://www.instagram.com/direct/t/123/'), t = tracker(); t.observe(snap(dom), ['alice'], NOW);
  append(dom,{id:'mention',label:'',body:'My outgoing <a href="/alice/">@alice</a>'}); assert.deepEqual(t.observe(snap(dom), ['alice'], NOW+1000), []);
  const noBinding = {allowedSenders:['alice']}, t2 = tracker(); t2.observe(snap(dom,noBinding), ['alice'], NOW);
  append(dom,{id:'mention2',body:'Someone mentions <a href="/alice/">@alice</a>'}); assert.deepEqual(t2.observe(snap(dom,noBinding), ['alice'], NOW+2000), []);
});
test('repeated identical messages with distinct IDs both emit', () => {
  const dom = fixture('thread','https://www.instagram.com/direct/t/123/'), t = tracker(); t.observe(snap(dom), ['alice'], NOW);
  append(dom,{id:'repeat1',body:'❤️'}); const a = t.observe(snap(dom), ['alice'], NOW+1000);
  append(dom,{id:'repeat2',body:'❤️'}); const b = t.observe(snap(dom), ['alice'], NOW+2000);
  assert.equal(a.length,1); assert.equal(b.length,1); assert.notEqual(a[0].eventId,b[0].eventId);
});
test('history prepend, stale timestamp, and tail replacement rebaseline', () => {
  const dom = fixture('thread','https://www.instagram.com/direct/t/123/'), t = tracker(); t.observe(snap(dom), ['alice'], NOW);
  const older = append(dom,{id:'older',timestamp:'2026-10-01T01:00:00Z'}); dom.window.document.querySelector('#messages').prepend(older);
  assert.deepEqual(t.observe(snap(dom), ['alice'], NOW+1000), []);
  append(dom,{id:'stale',timestamp:'2026-10-01T01:00:00Z'}); assert.deepEqual(t.observe(snap(dom), ['alice'], NOW+2000), []);
  dom.window.document.querySelector('#messages').innerHTML=''; append(dom,{id:'virtualized'}); assert.deepEqual(t.observe(snap(dom), ['alice'], NOW+3000), []);
});
test('startup hydration is a settling baseline, not new DM delivery', () => {
  const dom = fixture('thread','https://www.instagram.com/direct/t/123/'), t = new D.Tracker(); t.observe(snap(dom), ['alice'], NOW);
  append(dom,{id:'hydrated-old',timestamp:''}); assert.deepEqual(t.observe(snap(dom), ['alice'], NOW+1000), []);
  assert.deepEqual(t.observe(snap(dom), ['alice'], NOW+4500), []);
  append(dom,{id:'after-settle'}); assert.equal(t.observe(snap(dom), ['alice'], NOW+5000).length,1);
});
test('SPA thread switch and explicit reset suppress a new transcript baseline', () => {
  const dom = fixture('thread','https://www.instagram.com/direct/t/123/'), t = tracker(); t.observe(snap(dom), ['alice'], NOW);
  dom.reconfigure({url:'https://www.instagram.com/direct/t/456/'});
  append(dom); assert.deepEqual(t.observe(snap(dom,{...cfg,bindings:{456:'alice'}}), ['alice'], NOW+1000), []);
  t.reset(); assert.deepEqual(t.observe(snap(dom,{...cfg,bindings:{456:'alice'}}), ['alice'], NOW+2000), []);
});
test('invalid selectors and unsupported DOM fail closed with diagnosis', () => {
  const dom = fixture('unsupported'); const a = snap(dom); assert.equal(a.diagnostics.supported,false); assert.deepEqual(tracker().observe(a,['alice'],NOW),[]);
  const b = snap(dom,{...cfg,selectors:{messageRow:'['}}); assert.equal(b.diagnostics.invalidSelector,true); assert.deepEqual(b.inbox,[]);
});
test('calibrated incoming selector requires explicit binding and suppresses ambiguity', () => {
  const dom = fixture('thread','https://www.instagram.com/direct/t/123/'), t = tracker();
  const calibrated = {...cfg,selectors:{incomingMessage:'.incoming',messageText:'.body'}};
  t.observe(snap(dom,calibrated),['alice'],NOW);
  const row = append(dom,{id:'calibrated',label:'',body:''}); row.className='incoming'; row.innerHTML='<span class="body">Calibrated DM</span>';
  assert.equal(t.observe(snap(dom,calibrated),['alice'],NOW+1000).length,1);
});
test('explicit @username accessible label supplies identity, plain display name does not', () => {
  const dom=fixture('thread','https://www.instagram.com/direct/t/123/'), t=tracker(), config={allowedSenders:['alice']};
  t.observe(snap(dom,config),['alice'],NOW);
  append(dom,{id:'explicit-handle',label:'Message from @alice',body:'Handle identified'});
  assert.equal(t.observe(snap(dom,config),['alice'],NOW+1000).length,1);
  append(dom,{id:'display-name',label:'Message from Alice',body:'Only a display name'});
  assert.deepEqual(t.observe(snap(dom,config),['alice'],NOW+2000),[]);
});
test('Message sent by you is outgoing even with a verified sender binding', () => {
  const dom=fixture('thread','https://www.instagram.com/direct/t/123/'),t=tracker();t.observe(snap(dom),['alice'],NOW);
  append(dom,{id:'self-label',label:'Message sent by you',body:'My outgoing DM'});
  assert.deepEqual(t.observe(snap(dom),['alice'],NOW+1000),[]);
});
test('active supported thread suppresses delayed sidebar preview duplicates', () => {
  const dom=fixture('thread','https://www.instagram.com/direct/t/123/');
  const sidebar=dom.window.document.createElement('aside'); sidebar.innerHTML='<a href="/direct/t/123/" aria-label="Unread conversation" aria-describedby="preview-current"><span dir="auto">Alice</span><span dir="auto" id="preview-current">Old</span></a>';dom.window.document.body.append(sidebar);
  const t=tracker();t.observe(snap(dom),['alice'],NOW);
  append(dom,{id:'new-main',body:'Fresh'}); assert.equal(t.observe(snap(dom),['alice'],NOW+1000).length,1);
  dom.window.document.getElementById('preview-current').textContent='Fresh';assert.deepEqual(t.observe(snap(dom),['alice'],NOW+2000),[]);
});
test('very long transcripts inspect the tail and expose the scan cap', () => {
  const dom=fixture('thread','https://www.instagram.com/direct/t/123/');
  for(let i=0;i<505;i++)append(dom,{id:'bulk'+i,label:'You sent',body:'Previous'});
  const t=tracker();const base=snap(dom);assert.equal(base.diagnostics.capped,true);t.observe(base,['alice'],NOW);
  append(dom,{id:'tail',body:'Newest at tail'});assert.equal(t.observe(snap(dom),['alice'],NOW+1000).length,1);
});
test('identical unkeyed history rows do not shift occurrence IDs into false new DMs', () => {
  const dom=fixture('thread','https://www.instagram.com/direct/t/123/'); dom.window.document.querySelector('#messages').innerHTML='';
  append(dom,{id:'',body:'Same old text',timestamp:''});append(dom,{id:'',body:'Same old text',timestamp:''});
  const t=tracker();t.observe(snap(dom),['alice'],NOW);
  const older=append(dom,{id:'',body:'Same old text',timestamp:''});dom.window.document.querySelector('#messages').prepend(older);
  assert.deepEqual(t.observe(snap(dom),['alice'],NOW+1000),[]);
});
