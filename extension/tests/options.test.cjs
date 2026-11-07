const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path');
const { JSDOM } = require('jsdom');
const C = require('../common.js');
const { ConfigSync, summary } = require('../config-sync.js');
function fixture(app = { username: 'fixture.app', threadId: '333' }) {
  const dom = new JSDOM(fs.readFileSync(path.join(__dirname, '../options.html'), 'utf8'), { runScripts: 'outside-only', url: 'chrome-extension://fixture/options.html' });
  const { window } = dom, requests = [], writes = [];
  const data = { settings: C.settings({ allowedSenders: ['fixture.one', 'fixture.two'], bindings: { '111': 'fixture.one', '222': 'fixture.two' } }) };
  let serial = Promise.resolve();
  const sync = new ConfigSync({ get: async keys => Object.fromEntries(keys.filter(key => data[key] !== undefined).map(key => [key, structuredClone(data[key])])),
    set: async value => { writes.push(structuredClone(value)); Object.assign(data, structuredClone(value)); },
    nativeRequest: async () => ({ version: 1, type: 'config', ok: true, instagram: app }),
    exclusive: operation => { const job = serial.then(operation); serial = job.catch(() => {}); return job; } });
  window.PetCommon = C;
  window.setInterval = () => 1;
  window.chrome = {
    runtime: { id: 'fixture', sendMessage: (message, callback) => {
      requests.push(structuredClone(message));
      const work = message.type === 'pet.config.sync' ? sync.sync()
        : message.type === 'pet.settings.save' ? sync.saveManual(message.settings)
        : Promise.resolve({ ok: true, diagnostics: {}, appConfig: summary(data) });
      work.then(callback);
    } },
    storage: { local: { get: async keys => Object.fromEntries(keys.filter(key => data[key] !== undefined).map(key => [key, structuredClone(data[key])])) } }
  };
  window.eval(fs.readFileSync(path.join(__dirname, '../options.js'), 'utf8'));
  const drain = async () => { for (let i = 0; i < 6; i++) await new Promise(resolve => setImmediate(resolve)); };
  return { dom, data, requests, writes, drain, $: id => window.document.getElementById(id) };
}
test('options opening syncs app config while displaying preserved manual values and priority notice', async () => {
  const f = fixture();
  try {
    await f.drain();
    assert.equal(f.requests[0].type, 'pet.config.sync');
    assert.equal(f.$('senders').value, 'fixture.one\nfixture.two');
    assert.equal(f.$('bindings').value, '111 = fixture.one\n222 = fixture.two');
    assert.match(f.$('appConfigNotice').textContent, /app.*takes priority/);
    assert.deepEqual(f.data.settings.allowedSenders, ['fixture.app']);
    assert.equal(f.$('senders').disabled, false);
  } finally { f.dom.window.close(); }
});
test('options manual save keeps app override effective and preserves editable values for later use', async () => {
  const f = fixture();
  try {
    await f.drain();
    f.$('senders').value = 'fixture.manual'; f.$('bindings').value = '444 = fixture.manual';
    f.$('confirmed').checked = true; f.$('save').click(); await f.drain();
    assert.equal(f.requests.filter(value => value.type === 'pet.settings.save').length, 1);
    assert.deepEqual(f.data.manualSettings.allowedSenders, ['fixture.manual']);
    assert.deepEqual(f.data.settings.allowedSenders, ['fixture.app']);
    assert.match(f.$('feedback').textContent, /still takes priority/);
  } finally { f.dom.window.close(); }
});
test('invalid manual input shows a field error without submitting or saving', async () => {
  const f = fixture();
  try {
    await f.drain(); const before = structuredClone(f.data);
    f.$('senders').value = 'bad username'; f.$('save').click(); await f.drain();
    assert.equal(f.requests.some(value => value.type === 'pet.settings.save'), false);
    assert.deepEqual(f.data, before); assert.match(f.$('feedback').textContent, /Invalid username/);
  } finally { f.dom.window.close(); }
});
test('options notice explains that an explicitly blank app selection disables Instagram', async () => {
  const f = fixture({ username: '', threadId: '' });
  try {
    await f.drain(); assert.match(f.$('appConfigNotice').textContent, /disabled by the pet app/);
    assert.equal(f.data.settings.enabled, false);
    assert.equal(f.$('enabled').checked, true); // The manual global pause value is preserved.
  } finally { f.dom.window.close(); }
});
