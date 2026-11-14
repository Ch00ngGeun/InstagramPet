(function (root) {
  "use strict";
  const C = root.PetCommon || require("./common.js");
  const MAX_PENDING = 100, MAX_SEEN = 500, OBSERVATION_TTL = 5 * 60 * 1000, PENDING_TTL = 24 * 60 * 60 * 1000, SEEN_TTL = 24 * 60 * 60 * 1000, CONTENT_WINDOW = 10 * 1000;
  function validateEvent(raw, allowed, allowTest = false, now = Date.now()) {
    if (!raw || raw.version !== 1 || raw.type !== "dm") throw new Error("Invalid event envelope");
    if (typeof raw.eventId !== "string" || !/^[A-Za-z0-9._:-]{1,128}$/.test(raw.eventId) || /[\r\n]/.test(raw.eventId)) throw new Error("Invalid event identity");
    const sender = C.username(raw.sender);
    if (!sender || sender !== raw.sender) throw new Error("Invalid normalized sender");
    if (!allowTest && !allowed.includes(sender)) throw new Error("Sender is not allowlisted");
    if (!["thread-message", "inbox-preview", ...(allowTest ? ["test"] : [])].includes(raw.kind)) throw new Error("Invalid observation kind");
    const link = C.threadURL(raw.threadUrl);
    if (!link || link.url !== raw.threadUrl) throw new Error("Invalid thread link");
    if (typeof raw.text !== "string" || !raw.text.trim() || Array.from(raw.text).length > 2000) throw new Error("Invalid message text");
    const observed = Date.parse(raw.observedAt);
    if (!Number.isFinite(observed) || Math.abs(observed - now) > OBSERVATION_TTL) throw new Error("Stale observation");
    const event = { version: 1, type: "dm", eventId: raw.eventId, sender, text: raw.text, threadUrl: link.url,
      observedAt: new Date(observed).toISOString(), kind: raw.kind };
    if (typeof raw.displayName === "string") event.displayName = C.clip(raw.displayName, 100);
    return event;
  }
  const fingerprint = event => C.hash([event.sender, event.threadUrl, event.text].join("\u001f"));
  const sameContent = (entry, event) => event.kind !== "test" && entry.fingerprint === fingerprint(event)
    && Math.abs(entry.observedAt - Date.parse(event.observedAt)) <= CONTENT_WINDOW;
  class BridgeQueue {
    constructor({ get, set, nativeRequest, now = () => Date.now() }) {
      this.get = get; this.set = set; this.nativeRequest = nativeRequest; this.now = now;
      this.serial = Promise.resolve();
    }
    exclusive(operation) {
      const job = this.serial.then(operation);
      this.serial = job.catch(() => {});
      return job;
    }
    async load() {
      const data = await this.get(["pending", "seen", "settings", "bridge"]), now = this.now();
      const cfg = C.settings(data.settings);
      const stored = Array.isArray(data.pending) ? data.pending : [];
      let dropReason;
      const pending = stored.filter(x => {
        if (!x?.event || !Number.isFinite(x.savedAt)) return false;
        if (now - x.savedAt > PENDING_TTL) { dropReason = "expired"; return false; }
        // An empty selection can be transient during app/manual synchronization. Pause, retain, and expire normally.
        if (x.event.kind !== "test" && cfg.allowedSenders.length && !cfg.allowedSenders.includes(x.event.sender)) {
          dropReason ||= "selection-changed"; return false;
        }
        return true;
      }).slice(-MAX_PENDING);
      if (dropReason) await this.set({ pending, lastDrop: { reason: dropReason, at: now } });
      const seen = (Array.isArray(data.seen) ? data.seen : []).filter(x => x && typeof x.id === "string" && now - x.at <= SEEN_TTL).slice(-MAX_SEEN);
      return { pending, seen, config: cfg, bridge: data.bridge || { state: "not-tested" } };
    }
    enqueue(raw, allowTest = false) {
      return this.exclusive(async () => {
        const state = await this.load();
        if (!allowTest && !state.config.enabled) throw new Error("Detection disabled");
        const event = validateEvent(raw, state.config.allowedSenders, allowTest, this.now());
        if (state.seen.some(x => x.id === event.eventId || sameContent(x, event)) || state.pending.some(x =>
          x.event.eventId === event.eventId || (x.event.kind !== "test" && sameContent({ fingerprint: fingerprint(x.event), observedAt: Date.parse(x.event.observedAt) }, event)))) return { ok: true, duplicate: true };
        // Drop oldest by explicit bounded local policy; expose a counter to the user.
        const overflow = state.pending.length >= MAX_PENDING;
        state.pending.push({ event, savedAt: this.now() });
        state.pending = state.pending.slice(-MAX_PENDING);
        await this.set({ pending: state.pending, seen: state.seen, ...(overflow ? { lastDrop: { reason: "queue-full", at: this.now() } } : {}) });
        return { ok: true, queued: true };
      });
    }
    flush() {
      return this.exclusive(async () => {
        const state = await this.load();
        await this.set({ pending: state.pending, seen: state.seen });
        while (state.pending.length) {
          const index = state.pending.findIndex(item => item.event.kind === "test" ||
            (state.config.enabled && state.config.allowedSenders.includes(item.event.sender)));
          if (index < 0) break;
          const first = state.pending[index];
          try {
            const response = await this.nativeRequest(first.event);
            if (response?.type === "error") {
              state.pending.splice(index, 1);
              await this.set({ pending: state.pending, lastDrop: { reason: "host-rejected", at: this.now() } });
              continue;
            }
            if (response?.type !== "ack" || response.eventId !== first.event.eventId || response.ok !== true) throw new Error(response?.error || "Host did not acknowledge event");
            state.seen.push({ id: first.event.eventId, at: this.now(),
              ...(first.event.kind !== "test" ? { fingerprint: fingerprint(first.event), observedAt: Date.parse(first.event.observedAt) } : {}) });
            state.seen = state.seen.slice(-MAX_SEEN);
            state.pending.splice(index, 1);
            state.bridge = { state: "connected", at: this.now(), lastAcceptedAt: this.now() };
            await this.set({ pending: state.pending, seen: state.seen, bridge: state.bridge });
          } catch (error) {
            state.bridge = { state: "error", at: this.now(), error: C.clip(error.message, 250) };
            await this.set({ bridge: state.bridge });
            break;
          }
        }
        return { pending: state.pending.length, bridge: state.bridge };
      });
    }
    ping() {
      return this.exclusive(async () => {
        try {
          const response = await this.nativeRequest({ version: 1, type: "ping" });
          if (response?.type !== "pong" || response.ok !== true) throw new Error(response?.error || "Invalid host ping reply");
          const bridge = { state: "connected", at: this.now(), appInstalled: response.appInstalled, queueDepth: response.queueDepth };
          await this.set({ bridge });
          return { ok: true, bridge };
        } catch (error) {
          const bridge = { state: "error", at: this.now(), error: C.clip(error.message, 250) };
          await this.set({ bridge });
          return { ok: false, bridge };
        }
      });
    }
  }
  const api = { BridgeQueue, validateEvent, MAX_PENDING, OBSERVATION_TTL, PENDING_TTL, SEEN_TTL };
  root.PetWorker = api;
  if (typeof module !== "undefined") module.exports = api;
})(globalThis);
