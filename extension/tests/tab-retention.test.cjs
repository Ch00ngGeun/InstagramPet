// 탭 유지 검사: 관찰 중인 DM 탭만 자동 정리에서 제외되고, 워커가 다시 시작돼도
// 원래 값이 복원된다. 등록된 대화방마다 고정된 탭이 있고, 탭이 계속 늘어나지 않는다.
const { test } = require('node:test');
const assert = require('node:assert/strict');
globalThis.PetCommon = require('../common.js');
const { TabRetention } = require('../tab-retention.js');

function fixture() {
  const settings = { enabled: true, allowedSenders: ['fixture.sender'] }, session = {}, updates = [], created = [], windows = [5];
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
      update: async (id, change) => { updates.push([id, change]); Object.assign(tabs.get(id), change); },
      create: async props => { const id = 100 + tabs.size; tabs.set(id, { id, autoDiscardable: true, ...props }); created.push(props); return { id }; }
    }, windows: { getAll: async () => windows.map(id => ({ id })) }
  };
  return { chrome, settings, session, updates, created, windows, tabs, retention: new TabRetention(chrome) };
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

test('each bound thread keeps one pinned tab: an open one is pinned, a missing one opens in the background', async () => {
  const f = fixture();
  f.settings.bindings = { fixture: 'fixture.sender', '42': 'second.sender' };
  await f.retention.ensurePinned();
  assert.deepEqual(f.updates, [[1, { pinned: true }]]);
  assert.deepEqual(f.created, [{ windowId: 5, url: 'https://www.instagram.com/direct/t/42/', active: false, pinned: true }]);
  await f.retention.ensurePinned();
  assert.equal(f.updates.length, 1); assert.equal(f.created.length, 1);
});

test('a tab we opened that redirects is not reopened every minute; it reopens only after it is closed', async () => {
  const f = fixture();
  f.settings.bindings = { '42': 'second.sender' };
  await f.retention.ensurePinned();
  const opened = f.session.petOpenedTabs['42'];
  f.tabs.get(opened).url = 'https://www.instagram.com/accounts/login/';
  await f.retention.ensurePinned();
  assert.equal(f.created.length, 1);
  f.tabs.delete(opened);
  await f.retention.ensurePinned();
  assert.equal(f.created.length, 2);
});

test('nothing opens while observation is off, without bound threads, or when Chrome has no window', async () => {
  const f = fixture();
  await f.retention.ensurePinned();
  f.settings.bindings = { '42': 'second.sender' }; f.settings.enabled = false;
  await f.retention.ensurePinned();
  f.settings.enabled = true; f.windows.length = 0;
  await f.retention.ensurePinned();
  assert.equal(f.created.length, 0); assert.equal(f.updates.length, 0);
});
