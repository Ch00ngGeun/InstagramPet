const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');
const source = fs.readFileSync(path.join(__dirname, '../numeric-probe.js'), 'utf8');

function fixture({ fail = false, localConfig = {} } = {}) {
  const dom = new JSDOM('<!doctype html><html></html>', { runScripts: 'outside-only' });
  const { window } = dom;
  let reloaded = 0;
  window.chrome = {
    runtime: { reload: () => { reloaded++; } },
    tabs: { query: async () => {
      if (fail) throw new Error('fixture failure');
      return [
        { id: 123, url: 'https://www.instagram.com/direct/t/private-fixture/', title: 'private title', pinned: true, autoDiscardable: false },
        { id: 124, url: 'https://www.instagram.com/direct/inbox/', autoDiscardable: true, discarded: true, frozen: true },
        { id: 125, url: 'https://www.instagram.com/private-fixture/', title: 'another private title' }
      ];
    } },
    storage: {
      session: { get: async () => ({ petRetainedTabs: [[123, true]] }) },
      local: { get: async () => ({ settings: { enabled: true, allowedSenders: ['private.fixture'] },
        diagnostics: { '123': { state: 'observing', at: Date.now() },
          '999': { state: 'observing', at: Date.now() }, '124': { state: 'observing', at: Date.now() - 120001 } }, ...localConfig }) }
    }
  };
  window.eval(source);
  return {
    dom,
    get reloaded() { return reloaded; },
    async request(command) {
      const root = window.document.documentElement;
      root.removeAttribute('data-pet-numeric-result');
      root.setAttribute('data-pet-numeric-command', command);
      root.dispatchEvent(new window.Event('pet-numeric-probe'));
      await new Promise(resolve => setImmediate(resolve));
      const value = root.getAttribute('data-pet-numeric-result');
      return value ? JSON.parse(value) : null;
    }
  };
}

test('numeric options probe reports DM counts without exposing tab metadata or IDs', async () => {
  const f = fixture();
  try {
    const result = await f.request('tabs');
    assert.deepEqual(result, { ready: 1, totalTabs: 2, directTabs: 2,
      observationEnabled: 1, allowedSenders: 1, manualAllowedSenders: 1, manualBindings: 0,
      appConfigManaged: 0, appConfigDisabled: 0, appConfigSynced: 0, appConfigUnavailable: 0,
      recentDiagnosticTabs: 1, observingTabs: 1,
      pinned: 1, autoDiscardDisabled: 1,
      discarded: 1, frozen: 1, retained: 1 });
    assert.ok(Object.values(result).every(value => typeof value === 'number'));
    assert.equal(f.reloaded, 0);
  } finally { f.dom.window.close(); }
});

test('numeric options probe reloads only on the explicit reload command', async () => {
  const f = fixture();
  try {
    assert.equal(await f.request('unrecognized'), null);
    assert.equal(f.reloaded, 0);
    assert.deepEqual(await f.request('reload'), { ready: 1, reloadScheduled: 1 });
    assert.equal(f.reloaded, 1);
  } finally { f.dom.window.close(); }
});

test('numeric options probe returns a fixed numeric error when tab queries fail', async () => {
  const f = fixture({ fail: true });
  try { assert.deepEqual(await f.request('tabs'), { ready: 1, queryError: 1 }); }
  finally { f.dom.window.close(); }
});
test('numeric options probe verifies app management and preserved manual counts without returning selections', async () => {
  const f = fixture({ localConfig: {
    manualSettings: { allowedSenders: ['fixture.one', 'fixture.two'], bindings: { '111': 'fixture.one', '222': 'fixture.two' } },
    appInstagram: { username: '', threadId: '' }, appConfigSync: { state: 'managed', at: Date.now() }
  } });
  try {
    const result = await f.request('tabs');
    assert.equal(result.appConfigManaged, 1); assert.equal(result.appConfigDisabled, 1);
    assert.equal(result.appConfigSynced, 1); assert.equal(result.appConfigUnavailable, 0);
    assert.equal(result.manualAllowedSenders, 2); assert.equal(result.manualBindings, 2);
    assert.ok(Object.values(result).every(value => typeof value === 'number'));
    assert.doesNotMatch(JSON.stringify(result), /fixture\.(one|two)|111|222/);
  } finally { f.dom.window.close(); }
});
