(() => {
  "use strict";
  const C = PetCommon, D = PetDetector;
  const tracker = new D.Tracker(), outbox = new Map();
  let readSent = false, config = C.settings(), timer = null, lastPath = "", lastScan = 0, stopped = false, lastDiagnostic = 0, running = false, rerun = false;
  const metadata = { scans: 0, observations: 0, sendErrors: 0, dropped: 0 };
  function send(message) {
    return new Promise(resolve => {
      try {
        chrome.runtime.sendMessage(message, response => {
          if (chrome.runtime.lastError) { metadata.sendErrors++; resolve(null); }
          else resolve(response);
        });
      } catch { stopped = true; observer.disconnect(); clearInterval(poll); resolve(null); }
    });
  }
  function schedule() {
    if (stopped || timer) return;
    timer = setTimeout(() => { timer = null; scan(); }, 250);
  }
  async function scan() {
    if (stopped) return;
    if (running) { rerun = true; return; }
    running = true;
    try {
      const now = Date.now(), path = location.pathname;
      // A long renderer pause is a gap, not a license to announce an old transcript.
      if (path !== lastPath || now - lastScan > 120000) tracker.reset();
      lastPath = path; lastScan = now;
      const onDirect = /^\/direct(?:\/|$)/.test(path);
      let diagnostics = { supported: false };
      if (config.enabled && config.allowedSenders.length && onDirect) {
        const snapshot = D.scan(document, location.href, config);
        diagnostics = snapshot.diagnostics;
        metadata.scans++;
        for (const event of tracker.observe(snapshot, config.allowedSenders, now)) {
          metadata.observations++;
          outbox.set(event.eventId, event);
          readSent = false; // a new message while the user is looking at this thread is read too
        }
        while (outbox.size > 50) { outbox.delete(outbox.keys().next().value); metadata.dropped++; }
        for (const [id, event] of outbox) {
          if (now - Date.parse(event.observedAt) > 300000) { outbox.delete(id); metadata.dropped++; continue; }
          const response = await send({ type: "pet.observation", event });
          // Advance a transient content outbox only when the worker persisted or deduplicated it.
          if (response?.ok) outbox.delete(id);
          else break;
        }
      } else { tracker.reset(); outbox.clear(); }
      // The user is looking at this thread in a focused window: its pet bubbles can go away.
      const thread = C.threadURL(location.href);
      if (config.enabled && thread && document.visibilityState === "visible" && document.hasFocus()) {
        if (!readSent) { readSent = true; if (!(await send({ type: "pet.read", threadUrl: thread.url }))?.ok) readSent = false; }
      } else readSent = false;
      if (now - lastDiagnostic > 5000) {
        lastDiagnostic = now;
        const state = !config.enabled ? "disabled" : !config.allowedSenders.length ? "no-allowlist" : !onDirect ? "open-dm-page" : diagnostics.invalidSelector ? "invalid-selector" : diagnostics.supported ? "observing" : "unsupported-dom";
        await send({ type: "pet.diagnostics", info: { state, ...metadata, ...diagnostics, contentPending: outbox.size, page: C.threadURL(location.href) ? "thread" : onDirect ? "inbox" : "other", at: now } });
        if (config.debug) console.debug("[Instagram Pet]", state, { scans: metadata.scans, observations: metadata.observations, ...diagnostics });
      }
    } finally { running = false; if (rerun) { rerun = false; schedule(); } }
  }
  const observer = new MutationObserver(schedule);
  observer.observe(document.documentElement, { childList: true, subtree: true, characterData: true,
    attributes: true, attributeFilter: ["aria-label", "aria-hidden", "aria-describedby", "href", "datetime", "title"] });
  const poll = setInterval(schedule, 5000); // SPA navigation and missed renderer updates; Chrome may throttle this.
  addEventListener("pageshow", event => { if (event.persisted) tracker.reset(); schedule(); });
  addEventListener("pagehide", () => tracker.reset());
  addEventListener("focus", schedule);
  addEventListener("blur", schedule);
  document.addEventListener("visibilitychange", schedule);
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && changes.settings) { config = C.settings(changes.settings.newValue); tracker.reset(); outbox.clear(); schedule(); }
  });
  chrome.storage.local.get("settings", result => { config = C.settings(result.settings); schedule(); });
})();
