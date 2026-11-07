const { test } = require('node:test');
const assert = require('node:assert/strict');
globalThis.PetCommon = require('../common.js');
const { TabRetention } = require('../tab-retention.js');

function fixture() {
  const settings = { enabled: true, allowedSenders: ['fixture.sender'] }, session = {}, updates = [];
  const tabs = new Map([
    [1, { id: 1, url: 'https://www.instagram.com/direct/t/fixture/', autoDiscardable: true }],
    [2, { id: 2, url: 'https://www.instagram.com/fixture.sender/', autoDiscardable: true }],
    [3, { id: 3, url: 'https://www.instagram.com/direct/inbox/', autoDiscardable: false }],
    [4, { id: 4, url: 'https://example.invalid/direct/', autoDiscardable: true }]
  ]);
  const chrome = {
    storage: { local: { get: async () => ({ settings }) }, session: {
      get: async () => structuredClone(session), set: async data => Object.assign(session, structuredClone(data))
    } }, tabs: {
      query: async () => [...tabs.values()].filter(tab => new URL(tab.url).hostname === 'www.instagram.com'),
      get: async id => { if (!tabs.has(id)) throw new Error('Closed'); return { ...tabs.get(id) }; },
      update: async (id, change) => { updates.push([id, change]); Object.assign(tabs.get(id), change); }
    }
  };
  return { chrome, settings, session, updates, tabs, retention: new TabRetention(chrome) };
}

test('only allowlisted observation-enabled Instagram DM tabs are protected from automatic discard', async () => {
  const f = fixture();
  await f.retention.refresh();
  assert.deepEqual(f.updates, [[1, { autoDiscardable: false }]]);
  assert.equal(f.tabs.get(2).autoDiscardable, true);
  assert.equal(f.tabs.get(4).autoDiscardable, true);
  assert.equal(JSON.stringify(f.session).includes('instagram'), false, 'Session state retained URLs');
});

test('disabling observations restores each tab prior value including an existing false', async () => {
  const f = fixture();
  await f.retention.refresh();
  f.settings.enabled = false;
  await f.retention.refresh();
  assert.equal(f.tabs.get(1).autoDiscardable, true);
  assert.equal(f.tabs.get(3).autoDiscardable, false);
  assert.deepEqual(f.session.petRetainedTabs, []);
});

test('worker restart preserves restoration after a protected tab navigates outside Instagram', async () => {
  const f = fixture();
  await f.retention.refresh();
  const resumed = new TabRetention(f.chrome);
  f.tabs.get(1).url = 'https://example.invalid/';
  await resumed.changed(1, { url: f.tabs.get(1).url }, f.tabs.get(1));
  assert.equal(f.tabs.get(1).autoDiscardable, true);
  assert.equal(f.session.petRetainedTabs.some(row => row[0] === 1), false);
});

test('ordinary updates do not loop and a completed DM navigation is protected without activation', async () => {
  const f = fixture();
  await f.retention.changed(2, { autoDiscardable: false }, f.tabs.get(2));
  assert.equal(f.updates.length, 0);
  f.tabs.get(2).url = 'https://www.instagram.com/direct/t/another-fixture/';
  await f.retention.changed(2, { status: 'complete' }, f.tabs.get(2));
  assert.deepEqual(f.updates, [[2, { autoDiscardable: false }]]);
  f.tabs.delete(2);
  await f.retention.removed(2);
  assert.deepEqual(f.session.petRetainedTabs, []);
});
