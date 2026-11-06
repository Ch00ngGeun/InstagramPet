const test = require('node:test');
const assert = require('node:assert/strict');
const { JSDOM } = require('jsdom');
const { readFileSync } = require('node:fs');
const path = require('node:path');

const probe = readFileSync(path.join(__dirname, '..', '..', 'scripts', 'dom-probe.js'), 'utf8');

test('dom probe prints structure only, never text, usernames, ids or classes', () => {
  const dom = new JSDOM(`<!doctype html><body><main><div class="x1secretcls" style="overflow:auto">
    <div role="row" data-message-id="mid.SECRET42" aria-label="Message from secret.user" aria-describedby="message.SECRET42 secret.user">
      <a href="/secret.user/"><img alt="secret.user's profile picture" src="https://cdn.example/secret.jpg"></a>
      <span dir="auto">Secret body text 비밀</span><time datetime="2026-11-06T01:00:00Z"></time></div>
    <div role="row" aria-label="You sent"><a href="/direct/t/998877/">x</a><span dir="auto">my secret reply</span></div>
  </div></main></body>`, { url: 'https://www.instagram.com/direct/t/998877/', runScripts: 'outside-only' });
  dom.window.console.log = () => {};
  const report = dom.window.eval(probe);
  for (const secret of ['secret', 'SECRET', '비밀', '998877', 'x1secretcls', 'cdn.example', '2026-11-06T01'])
    assert.ok(!report.includes(secret), `leaked ${secret}`);
  assert.match(report, /role="row"/);
  assert.match(report, /aria-label="in"/);
  assert.match(report, /aria-label="out"/);
  assert.match(report, /alt="profile"/);
  assert.match(report, /href="\/fixture\.user\/"/);
});
