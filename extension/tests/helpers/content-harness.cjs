const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const C = require('../../common.js');
const D = require('../../detector.js');

// Deterministic scheduling model, not a Chrome performance measurement. A nonzero
// quantum aligns timer wakeups; actual DOM-event/microtask delivery stays independent.
function contentHarness({ source, timerQuantum = 0, now = 10000, hidden = true, holdResponses = false } = {}) {
  const code = source ?? fs.readFileSync(path.join(__dirname, '../../content.js'), 'utf8');
  const tasks = new Map(), microtasks = [], listeners = new Map(), responses = [], sent = [], observations = [];
  let clock = now, nextTask = 1, mutation, scans = 0, resets = 0, disconnected = false;
  const rows = [{ key: 'fixture-history', node: {}, text: 'fixture baseline', incoming: true, outgoing: false,
    sender: 'fixture.sender', thread: 'fixture-thread', threadUrl: 'https://www.instagram.com/direct/t/fixture-thread/' }];
  const due = delay => timerQuantum ? Math.ceil((clock + delay) / timerQuantum) * timerQuantum : clock + delay;
  const timeout = (callback, delay, repeat = false) => {
    const id = nextTask++;
    tasks.set(id, { callback, at: due(delay), delay, repeat });
    return id;
  };
  class ClockDate extends Date { static now() { return clock; } }
  const document = { documentElement: {}, visibilityState: hidden ? 'hidden' : 'visible', hasFocus: () => false,
    addEventListener: (type, fn) => listeners.set(type, fn) };
  const chrome = {
    runtime: { sendMessage: (message, callback) => {
      sent.push(message);
      if (message.type === 'pet.observation') observations.push({ at: clock, event: message.event });
      if (holdResponses) responses.push(callback); else callback({ ok: true });
    } },
    storage: { onChanged: { addListener() {} }, local: { get: (key, callback) => callback({ settings: {
      enabled: true, allowedSenders: ['fixture.sender']
    } }) } }
  };
  const context = vm.createContext({ Date: ClockDate, PetCommon: C,
    PetDetector: { Tracker: class extends D.Tracker {
      constructor() { super({ warmupMs: 0 }); }
      reset() { resets++; super.reset(); }
    }, scan: () => { scans++; return { inbox: [], thread: { id: 'fixture-thread', supported: true, atBottom: true, rows: [...rows] }, diagnostics: { supported: true } }; } },
    document, location: { pathname: '/direct/t/fixture-thread/', href: 'https://www.instagram.com/direct/t/fixture-thread/' }, chrome,
    MutationObserver: class { constructor(callback) { mutation = callback; } observe() {} disconnect() { disconnected = true; } },
    setTimeout: (fn, delay) => timeout(fn, delay), clearTimeout: id => tasks.delete(id),
    setInterval: (fn, delay) => timeout(fn, delay, true), clearInterval: id => tasks.delete(id),
    queueMicrotask: fn => microtasks.push(fn), addEventListener: (type, fn) => listeners.set(type, fn),
    console: { debug() {} }
  });
  vm.runInContext(code, context, { filename: 'content.js' });

  async function drain() {
    for (let pass = 0; pass < 20; pass++) {
      while (microtasks.length) microtasks.shift()();
      await Promise.resolve();
    }
  }
  async function advance(to) {
    if (to < clock) throw new Error('Synthetic clock cannot move backwards');
    await drain();
    while (true) {
      const next = [...tasks.entries()].filter(([, task]) => task.at <= to).sort((a, b) => a[1].at - b[1].at || a[0] - b[0])[0];
      if (!next) break;
      const [id, task] = next;
      clock = task.at;
      tasks.delete(id);
      if (task.repeat) tasks.set(id, { ...task, at: due(task.delay) });
      task.callback();
      await drain();
    }
    clock = to;
    await drain();
  }
  return { drain, advance, sent, observations, responses, chrome, document,
    get now() { return clock; }, get scans() { return scans; }, get resets() { return resets; },
    get disconnected() { return disconnected; }, get timerCount() { return tasks.size; },
    mutate(text = 'fixture incoming') {
      rows.push({ ...rows[0], key: 'fixture-message-' + rows.length, node: {}, text });
      mutation([]);
    },
    signalMutation() { mutation([]); },
    dispatch(type) { listeners.get(type)?.({ persisted: false }); },
    releaseResponses() { for (const callback of responses.splice(0)) callback({ ok: true }); }
  };
}

module.exports = { contentHarness };
