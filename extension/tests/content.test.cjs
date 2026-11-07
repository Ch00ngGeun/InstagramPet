const { test } = require('node:test');
const assert = require('node:assert/strict');
const { contentHarness } = require('./helpers/content-harness.cjs');

test('hidden DOM mutation reaches the worker without advancing throttled timers', async () => {
  const f = contentHarness({ timerQuantum: 60000 });
  await f.drain();
  assert.equal(f.scans, 1);
  assert.equal(f.observations.length, 0, 'startup history was replayed');
  f.mutate();
  await f.drain();
  assert.equal(f.scans, 2);
  assert.equal(f.observations.length, 1);
  assert.equal(f.observations[0].at, f.now);
  assert.equal(f.timerCount, 1, 'DOM scans installed a delayed timer in addition to the fallback poll');
});

test('mutation bursts share one scan and retain the order of every appended message', async () => {
  const f = contentHarness();
  await f.drain();
  for (let index = 0; index < 20; index++) f.mutate('fixture ' + index);
  await f.drain();
  assert.equal(f.scans, 2);
  assert.deepEqual(f.observations.map(x => x.event.text), Array.from({ length: 20 }, (_, i) => 'fixture ' + i));
});

test('a DOM change while a worker acknowledgement is pending scans immediately after it completes', async () => {
  const f = contentHarness({ timerQuantum: 60000 });
  await f.drain();
  const send = f.chrome.runtime.sendMessage;
  let acknowledge;
  f.chrome.runtime.sendMessage = (message, callback) => {
    if (message.type === 'pet.observation' && !acknowledge) acknowledge = () => send(message, callback);
    else send(message, callback);
  };
  f.mutate('fixture first');
  await f.drain();
  f.mutate('fixture second');
  await f.drain();
  assert.equal(f.scans, 2, 'concurrent scan entered while delivery was pending');
  acknowledge();
  await f.drain();
  assert.equal(f.scans, 3);
  assert.deepEqual(f.observations.map(x => x.event.text), ['fixture first', 'fixture second']);
});

test('resume schedules a scan without waiting for the fallback interval', async () => {
  const f = contentHarness({ timerQuantum: 60000 });
  await f.drain();
  f.dispatch('resume');
  await f.drain();
  assert.equal(f.scans, 2);
});

test('invalidated extension stops observing and cancels its fallback poll', async () => {
  const f = contentHarness();
  await f.drain();
  f.chrome.runtime.sendMessage = () => { throw new Error('Extension context invalidated'); };
  f.mutate();
  await f.drain();
  assert.equal(f.disconnected, true);
  assert.equal(f.timerCount, 0);
  const scans = f.scans;
  f.signalMutation();
  await f.drain();
  assert.equal(f.scans, scans);
});
