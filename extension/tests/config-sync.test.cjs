const { test } = require('node:test');
const assert = require('node:assert/strict');
const C = require('../common.js');
const { ConfigSync, replyConfig } = require('../config-sync.js');
const manual = () => C.settings({ enabled: true, allowedSenders: ['fixture.one', 'fixture.two'],
  bindings: { '111': 'fixture.one', '222': 'fixture.two' }, debug: true, selectors: { messageRow: '.fixture-row' } });
const response = instagram => ({ version: 1, type: 'config', ok: true, instagram });
function fixture(initial = { settings: manual() }) {
  const data = structuredClone(initial), writes = [], requests = [];
  let reply = response(null), serial = Promise.resolve();
  const deps = { get: async keys => Object.fromEntries(keys.map(key => [key, structuredClone(data[key])])),
    set: async value => { writes.push(structuredClone(value)); Object.assign(data, structuredClone(value)); },
    nativeRequest: async value => { requests.push(value); if (reply instanceof Error) throw reply; return structuredClone(reply); },
    exclusive: operation => { const job = serial.then(operation); serial = job.catch(() => {}); return job; }, now: () => 1000 };
  return { data, writes, requests, deps, sync: new ConfigSync(deps), reply(value) { reply = value; } };
}
test('unmanaged app config preserves the existing multi-sender manual selection', async () => {
  const f = fixture(), before = structuredClone(f.data.settings);
  const result = await f.sync.sync();
  assert.equal(result.managed, false); assert.deepEqual(f.data.settings, before);
  assert.equal(f.data.manualSettings, undefined);
  assert.equal(f.writes.filter(value => value.settings).length, 0);
  assert.deepEqual(f.requests, [{ version: 1, type: 'config' }]);
});
test('app selection backs up manual values and overrides only sender and binding selection', async () => {
  const f = fixture(); f.reply(response({ username: 'fixture.app', threadId: '333' }));
  assert.equal((await f.sync.sync()).managed, true);
  assert.deepEqual(f.data.manualSettings, manual());
  assert.deepEqual(f.data.settings.allowedSenders, ['fixture.app']);
  assert.deepEqual(f.data.settings.bindings, { '333': 'fixture.app' });
  assert.equal(f.data.settings.debug, true); assert.deepEqual(f.data.settings.selectors, manual().selectors);
  assert.deepEqual(Object.keys(f.data.appInstagram).sort(), ['threadId', 'username']);
});
test('comma-separated app accounts pair each sender with its corresponding thread and retain manual values', async () => {
  const f = fixture(), original = structuredClone(f.data.settings);
  f.reply(response({ username: 'fixture.alpha,fixture.beta', threadId: '333,444' }));
  assert.equal((await f.sync.sync()).managed, true);
  assert.deepEqual(f.data.settings.allowedSenders, ['fixture.alpha', 'fixture.beta']);
  assert.deepEqual(f.data.settings.bindings, { '333': 'fixture.alpha', '444': 'fixture.beta' });
  assert.deepEqual(f.data.manualSettings, original);
  assert.deepEqual(f.data.settings.selectors, original.selectors);
  assert.equal(f.data.settings.debug, original.debug);
  f.reply(response(null)); await f.sync.sync();
  assert.deepEqual(f.data.settings, original);
});
test('one app account can bind multiple distinct threads without duplicating the allowlist', async () => {
  const f = fixture();
  f.reply(response({ username: 'fixture.same,fixture.same', threadId: '333,444' }));
  assert.equal((await f.sync.sync()).ok, true);
  assert.deepEqual(f.data.settings.allowedSenders, ['fixture.same']);
  assert.deepEqual(f.data.settings.bindings, { '333': 'fixture.same', '444': 'fixture.same' });
});
test('a full 100-pair app selection is applied without truncating its allowlist or bindings', async () => {
  const f = fixture(), names = Array.from({ length: 100 }, (_, i) => `fixture.account${i}`);
  const ids = names.map((_, i) => String(1000 + i));
  f.reply(response({ username: names.join(','), threadId: ids.join(',') }));
  assert.equal((await f.sync.sync()).ok, true);
  assert.deepEqual(f.data.settings.allowedSenders, names);
  assert.deepEqual(f.data.settings.bindings, Object.fromEntries(ids.map((id, i) => [id, names[i]])));
});
test('invalid CSV lists leave every last-valid app mapping and pending event unchanged', async () => {
  const f = fixture();
  f.reply(response({ username: 'fixture.alpha,fixture.beta', threadId: '333,444' })); await f.sync.sync();
  f.data.pending = [{ event: { kind: 'thread-message', sender: 'fixture.alpha', threadUrl: 'https://www.instagram.com/direct/t/333/' } }];
  const before = structuredClone(f.data);
  const tooManyNames = Array.from({ length: 101 }, (_, i) => `fixture.${i}`).join(',');
  const tooManyThreads = Array.from({ length: 101 }, (_, i) => String(i + 1)).join(',');
  for (const app of [
    { username: 'fixture.alpha,fixture.beta', threadId: '333' },
    { username: 'fixture.alpha', threadId: '333,444' },
    { username: ',fixture.alpha', threadId: '333,444' },
    { username: 'fixture.alpha,', threadId: '333,444' },
    { username: 'fixture.alpha,,fixture.beta', threadId: '333,444,555' },
    { username: 'fixture.alpha,fixture.beta', threadId: '333,' },
    { username: 'fixture.alpha,fixture.beta', threadId: '333,333' },
    { username: 'fixture.same,fixture.same', threadId: '333,333' },
    { username: 'fixture.alpha, fixture.beta', threadId: '333,444' },
    { username: 'fixture.alpha,fixture.beta', threadId: '333, 444' },
    { username: 'fixture.alpha,fixture.beta\n', threadId: '333,444' },
    { username: 'fixture.alpha,fixture.beta', threadId: '333,444\n' },
    { username: 'fixture.alpha，fixture.beta', threadId: '333,444' },
    { username: 'fixture.alpha,@fixture.beta', threadId: '333,444' },
    { username: 'fixture.alpha,Fixture.Beta', threadId: '333,444' },
    { username: 'fixture.alpha,fixture.beta', threadId: `333,${'4'.repeat(129)}` },
    { username: tooManyNames, threadId: tooManyThreads }
  ]) {
    f.reply(response(app)); const result = await f.sync.sync();
    assert.equal(result.ok, false); assert.equal(result.error, 'App settings could not be refreshed');
    assert.deepEqual(f.data.settings, before.settings);
    assert.deepEqual(f.data.manualSettings, before.manualSettings);
    assert.deepEqual(f.data.appInstagram, before.appInstagram);
    assert.deepEqual(f.data.pending, before.pending);
  }
});
test('unchanged multi-account polling is quiet and blanking then removing it restores the original selection', async () => {
  const f = fixture(), original = structuredClone(f.data.settings);
  f.reply(response({ username: 'fixture.alpha,fixture.beta', threadId: '333,444' })); await f.sync.sync();
  f.writes.length = 0;
  for (let i = 0; i < 3; i++) await f.sync.sync();
  assert.deepEqual(f.writes, []);
  f.reply(response({ username: '', threadId: '' })); await f.sync.sync();
  assert.equal(f.data.settings.enabled, false);
  assert.deepEqual(f.data.settings.allowedSenders, []); assert.deepEqual(f.data.settings.bindings, {});
  f.reply(response(null)); await f.sync.sync();
  assert.deepEqual(f.data.settings, original);
});
test('manual saves remain preserved without defeating app priority and global pause still works', async () => {
  const f = fixture(); f.reply(response({ username: 'fixture.app', threadId: '333' })); await f.sync.sync();
  const edited = C.settings({ enabled: false, allowedSenders: ['fixture.manual'], bindings: { '444': 'fixture.manual' } });
  assert.equal((await f.sync.saveManual(edited)).managed, true);
  assert.deepEqual(f.data.manualSettings, edited);
  assert.deepEqual(f.data.settings.allowedSenders, ['fixture.app']);
  assert.deepEqual(f.data.settings.bindings, { '333': 'fixture.app' });
  assert.equal(f.data.settings.enabled, false);
});
test('blank managed selection disables Instagram and removing management restores manual values', async () => {
  const f = fixture(); f.reply(response({ username: '', threadId: '' }));
  const result = await f.sync.sync();
  assert.equal(result.managed, true); assert.equal(result.disabled, true);
  assert.equal(f.data.settings.enabled, false); assert.deepEqual(f.data.settings.allowedSenders, []); assert.deepEqual(f.data.settings.bindings, {});
  f.reply(response(null)); await f.sync.sync();
  assert.deepEqual(f.data.settings, manual()); assert.deepEqual(f.data.manualSettings, manual());
  assert.equal(f.data.appInstagram, null);
});
test('unchanged app polling does not write settings, pending events, or trigger a new baseline', async () => {
  const f = fixture(); f.reply(response({ username: 'fixture.app', threadId: '333' })); await f.sync.sync();
  f.writes.length = 0;
  for (let i = 0; i < 4; i++) await f.sync.sync();
  assert.deepEqual(f.writes, []);
});
test('malformed or unsupported config replies never replace the last valid selection or echo input', async () => {
  const f = fixture(); f.reply(response({ username: 'fixture.app', threadId: '333' })); await f.sync.sync();
  const before = structuredClone(f.data.settings);
  for (const value of [
    { type: 'pong', ok: true, instagram: null }, response({ username: 'fixture.app', threadId: '12\n' }),
    response({ username: 'fixture.app\n', threadId: '12' }), response({ username: '@fixture.app', threadId: '12' }),
    response({ username: 'Fixture.App', threadId: '12' }), response({ username: 'fixture.app', threadId: 'x' }),
    response({ username: 'fixture.app', threadId: '1'.repeat(129) }), response({ username: '', threadId: '12' }),
    response({ username: 'fixture.app', threadId: '' }), response({ username: 'fixture.app', threadId: '12', messages: 'fixture@example.invalid' }),
    { ...response(null), messages: 'fixture@example.invalid' }, new Error('private fixture error')
  ]) {
    f.reply(value); const result = await f.sync.sync();
    assert.equal(result.ok, false); assert.equal(result.error, 'App settings could not be refreshed');
    assert.deepEqual(f.data.settings, before); assert.deepEqual(f.data.manualSettings, manual());
  }
  assert.equal(f.data.appConfigSync.state, 'unavailable');
});
test('changing a thread for the same sender drops obsolete queued events but preserves explicit demos', async () => {
  const f = fixture(); f.reply(response({ username: 'fixture.app', threadId: '333' })); await f.sync.sync();
  f.data.pending = [{ event: { kind: 'thread-message', sender: 'fixture.app', threadUrl: 'https://www.instagram.com/direct/t/333/' } },
    { event: { kind: 'test' } }];
  f.reply(response({ username: 'fixture.app', threadId: '444' })); await f.sync.sync();
  assert.deepEqual(f.data.pending, [{ event: { kind: 'test' } }]);
  f.data.pending.push({ event: { kind: 'thread-message' } });
  f.reply(new Error('unavailable')); await f.sync.sync();
  assert.equal(f.data.pending.length, 2);
});
test('worker restarts preserve the original manual backup and concurrent sync requests share one job', async () => {
  const f = fixture(); f.reply(response({ username: 'fixture.app', threadId: '333' }));
  await Promise.all([f.sync.sync(), f.sync.sync(), f.sync.sync()]);
  assert.equal(f.requests.length, 1);
  const restarted = new ConfigSync(f.deps); f.reply(response(null)); await restarted.sync();
  assert.deepEqual(f.data.settings, manual());
});
test('response validation rejects missing keys and oversized username fields', () => {
  for (const value of [{ version: 1, type: 'config', ok: true }, response([]), response({ username: 'x'.repeat(31), threadId: '1' })])
    assert.throws(() => replyConfig(value));
});
test('failed storage reads and writes return fixed errors without replacing the last valid settings', async () => {
  const f = fixture(), before = structuredClone(f.data.settings);
  f.reply(response({ username: 'fixture.app', threadId: '333' }));
  const failedWrite = new ConfigSync({ ...f.deps, set: async () => { throw new Error('private fixture storage failure'); } });
  const answer = await failedWrite.sync();
  assert.equal(answer.ok, false); assert.equal(answer.error, 'App settings could not be refreshed');
  assert.deepEqual(f.data.settings, before); assert.equal(f.data.manualSettings, undefined);
  const failedRead = new ConfigSync({ ...f.deps, get: async () => { throw new Error('private fixture storage failure'); } });
  assert.equal((await failedRead.sync()).error, 'App settings could not be refreshed');
  assert.equal((await failedRead.saveManual(manual())).error, 'Manual settings could not be saved');
  assert.deepEqual(f.data.settings, before);
});
test('an apply-write failure preserves the already-durable original manual backup', async () => {
  const f = fixture(), before = structuredClone(f.data.settings); let count = 0;
  f.reply(response({ username: 'fixture.app', threadId: '333' }));
  const partial = new ConfigSync({ ...f.deps, set: async changes => {
    count++; if (count === 2) throw new Error('fixture apply failure');
    await f.deps.set(changes);
  } });
  assert.equal((await partial.sync()).ok, false);
  assert.deepEqual(f.data.manualSettings, manual()); assert.deepEqual(f.data.settings, before);
  assert.equal(f.data.appInstagram, undefined);
});
test('a concurrent manual save and a deduplicated app poll are serialized without losing either selection', async () => {
  const f = fixture(); f.reply(response({ username: 'fixture.app', threadId: '333' }));
  const edited = C.settings({ allowedSenders: ['fixture.new'], bindings: { '444': 'fixture.new' }, debug: true });
  await Promise.all([f.sync.sync(), f.sync.saveManual(edited), f.sync.sync()]);
  assert.equal(f.requests.length, 1); assert.deepEqual(f.data.manualSettings, edited);
  assert.deepEqual(f.data.settings.allowedSenders, ['fixture.app']); assert.deepEqual(f.data.settings.bindings, { '333': 'fixture.app' });
  f.reply(response(null)); await f.sync.sync();
  assert.deepEqual(f.data.settings, edited);
});
test('a manual save queued before an app refresh is also retained under the new override', async () => {
  const f = fixture(); f.reply(response({ username: 'fixture.app', threadId: '333' }));
  const edited = C.settings({ allowedSenders: ['fixture.first'], bindings: { '555': 'fixture.first' } });
  await Promise.all([f.sync.saveManual(edited), f.sync.sync()]);
  assert.deepEqual(f.data.manualSettings, edited);
  assert.deepEqual(f.data.settings.allowedSenders, ['fixture.app']);
});
test('malformed manual save requests fail without partially sanitizing and storing input', async () => {
  const f = fixture(), before = structuredClone(f.data);
  for (const value of [null, {}, { ...manual(), allowedSenders: ['bad username'] }, { ...manual(), allowedSenders: [null] },
    { ...manual(), bindings: { '123': null } },
    { ...manual(), bindings: { '123\n': 'fixture.one' } }, { ...manual(), enabled: 'true' },
    { ...manual(), selectors: { unsupported: '.fixture-row' } }]) {
    assert.equal((await f.sync.saveManual(value)).ok, false);
    assert.deepEqual(f.data, before);
  }
});
