(function (root) {
  "use strict";
  const C = root.PetCommon || require("./common.js");
  const MAX_PENDING = 100, MAX_SEEN = 500, PENDING_TTL = 5 * 60 * 1000, SEEN_TTL = 24 * 60 * 60 * 1000;
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
    if (!Number.isFinite(observed) || Math.abs(observed - now) > PENDING_TTL) throw new Error("Stale observation");
    const event = { version: 1, type: "dm", eventId: raw.eventId, sender, text: raw.text, threadUrl: link.url,
      observedAt: new Date(observed).toISOString(), kind: raw.kind };
    if (typeof raw.displayName === "string") event.displayName = C.clip(raw.displayName, 100);
    return event;
  }
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
      const pending = (Array.isArray(data.pending) ? data.pending : []).filter(x => x?.event && Number.isFinite(x.savedAt) && now - x.savedAt <= PENDING_TTL && (x.event.kind === "test" || (cfg.enabled && cfg.allowedSenders.includes(x.event.sender)))).slice(-MAX_PENDING);
      const seen = (Array.isArray(data.seen) ? data.seen : []).filter(x => x && typeof x.id === "string" && now - x.at <= SEEN_TTL).slice(-MAX_SEEN);
      return { pending, seen, config: cfg, bridge: data.bridge || { state: "not-tested" } };
    }
    enqueue(raw, allowTest = false) {
      return this.exclusive(async () => {
        const state = await this.load();
        if (!allowTest && !state.config.enabled) throw new Error("Detection disabled");
        const event = validateEvent(raw, state.config.allowedSenders, allowTest, this.now());
        if (state.seen.some(x => x.id === event.eventId) || state.pending.some(x => x.event.eventId === event.eventId)) return { ok: true, duplicate: true };
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
          const first = state.pending[0];
          try {
            const response = await this.nativeRequest(first.event);
            if (response?.type !== "ack" || response.eventId !== first.event.eventId || response.ok !== true) throw new Error(response?.error || "Host did not acknowledge event");
            state.seen.push({ id: first.event.eventId, at: this.now() });
            state.seen = state.seen.slice(-MAX_SEEN);
            state.pending.shift();
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
  const api = { BridgeQueue, validateEvent, MAX_PENDING, PENDING_TTL, SEEN_TTL };
  root.PetWorker = api;
  if (typeof module !== "undefined") module.exports = api;
})(globalThis);
