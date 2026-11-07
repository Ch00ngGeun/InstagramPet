(function (root) {
  "use strict";
  const C = root.PetCommon || require("./common.js");
  const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
  const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  const selection = value => {
    const settings = C.settings(value);
    return [settings.enabled, settings.allowedSenders, settings.bindings];
  };
  function dropObsoletePending(data, desired, changes) {
    if (equal(selection(data.settings), selection(desired))) return;
    if (Array.isArray(data.pending) && data.pending.some(item => item?.event?.kind !== "test"))
      changes.pending = data.pending.filter(item => item?.event?.kind === "test");
  }

  function instagram(value) {
    if (value === null) return null; // No app override; keep manual settings.
    if (!value || typeof value !== "object" || Array.isArray(value)
        || Object.keys(value).sort().join(",") !== "threadId,username"
        || typeof value.username !== "string" || typeof value.threadId !== "string") throw new Error("Invalid app Instagram configuration");
    const { username, threadId } = value;
    if (!username && !threadId) return { username: "", threadId: "" };
    // The host supplies canonical CSV, with one thread for each username in the same order.
    // Validate every item before replacing any part of the effective selection.
    if (username.length > 3099 || threadId.length > 12899) throw new Error("Invalid app Instagram configuration");
    const usernames = username.split(","), threads = threadId.split(",");
    if (usernames.length > 100 || usernames.length !== threads.length
        || usernames.some(name => !name || C.username(name) !== name || !/^[a-z0-9._]{1,30}$/.test(name))
        || threads.some(id => !/^[0-9]{1,128}$/.test(id) || id.trim() !== id)
        || new Set(threads).size !== threads.length) throw new Error("Invalid app Instagram configuration");
    return { username, threadId };
  }
  function replyConfig(reply) {
    if (!reply || reply.version !== 1 || reply.type !== "config" || reply.ok !== true || !own(reply, "instagram")
        || Object.keys(reply).some(key => !["version", "type", "ok", "instagram"].includes(key))) throw new Error("Invalid app configuration response");
    return instagram(reply.instagram);
  }
  function effective(manual, app) {
    const result = C.settings(manual);
    if (app !== null) {
      const usernames = app.username ? app.username.split(",") : [], threads = app.threadId ? app.threadId.split(",") : [];
      result.allowedSenders = [...new Set(usernames)];
      result.bindings = Object.fromEntries(threads.map((id, index) => [id, usernames[index]]));
      if (!app.username) result.enabled = false;
    }
    return result;
  }
  function validateManual(raw) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw) || typeof raw.enabled !== "boolean" || typeof raw.debug !== "boolean"
        || !Array.isArray(raw.allowedSenders) || raw.allowedSenders.length > 100
        || raw.allowedSenders.some(value => typeof value !== "string" || C.username(value) !== value)
        || !raw.bindings || typeof raw.bindings !== "object" || Array.isArray(raw.bindings)
        || Object.keys(raw.bindings).length > 100
        || Object.entries(raw.bindings).some(([key, value]) => !/^[A-Za-z0-9_-]{1,128}$/.test(key) || key.trim() !== key || typeof value !== "string" || C.username(value) !== value)
        || !raw.selectors || typeof raw.selectors !== "object" || Array.isArray(raw.selectors)
        || Object.entries(raw.selectors).some(([key, value]) => !C.SELECTOR_KEYS.has(key) || typeof value !== "string" || value.length > 400)
        || Object.keys(raw).some(key => !["enabled", "debug", "allowedSenders", "bindings", "selectors"].includes(key))) throw new Error("Invalid manual settings");
    return C.settings(raw);
  }
  function summary(data) {
    const app = data.appInstagram;
    return { state: data.appConfigSync?.state || "not-synced", managed: app != null,
      disabled: app != null && app.username === "" };
  }
  class ConfigSync {
    constructor({ get, set, nativeRequest, exclusive, now = () => Date.now() }) {
      this.get = get; this.set = set; this.nativeRequest = nativeRequest;
      this.exclusive = exclusive; this.now = now; this.running = null;
    }
    sync() {
      if (this.running) return this.running;
      const job = this.exclusive(async () => {
        try {
          // The host returns only the Instagram selection. Never persist its raw response.
          const app = replyConfig(await this.nativeRequest({ version: 1, type: "config" }));
          const data = await this.get(["settings", "manualSettings", "appInstagram", "appConfigSync", "pending"]);
          const manual = C.settings(data.manualSettings || data.settings);
          const desired = effective(manual, app), changes = {};
          // Preserve the original editable selection before replacing any effective values.
          // If this write fails, the active selection is never touched.
          if (app !== null && !data.manualSettings) await this.set({ manualSettings: manual });
          if (!equal(data.settings, desired)) changes.settings = desired;
          dropObsoletePending(data, desired, changes);
          if (!own(data, "appInstagram") || !equal(data.appInstagram, app)) changes.appInstagram = app;
          const state = app === null ? "manual" : "managed";
          if (data.appConfigSync?.state !== state || own(changes, "settings") || own(changes, "appInstagram"))
            changes.appConfigSync = { state, at: this.now() };
          if (Object.keys(changes).length) await this.set(changes);
          return { ok: true, ...summary({ ...data, ...changes }) };
        } catch {
          // A missing/old host or invalid response leaves the last valid selection untouched.
          let data = {};
          try {
            data = await this.get(["appInstagram", "appConfigSync"]);
            if (data.appConfigSync?.state !== "unavailable") await this.set({ appConfigSync: { state: "unavailable", at: this.now() } });
          } catch { /* Storage failures must not echo provider messages or configuration values. */ }
          return { ok: false, ...summary({ ...data, appConfigSync: { state: "unavailable" } }), error: "App settings could not be refreshed" };
        }
      });
      this.running = job.finally(() => { this.running = null; });
      return this.running;
    }
    saveManual(raw) {
      return this.exclusive(async () => {
        try {
          const data = await this.get(["settings", "manualSettings", "appInstagram", "appConfigSync", "pending"]);
          const app = data.appInstagram === undefined ? null : instagram(data.appInstagram);
          const manual = validateManual(raw), desired = effective(manual, app), changes = {};
          if (!equal(data.manualSettings, manual)) changes.manualSettings = manual;
          if (!equal(data.settings, desired)) changes.settings = desired;
          dropObsoletePending(data, desired, changes);
          if (Object.keys(changes).length) await this.set(changes);
          return { ok: true, ...summary(data) };
        } catch { return { ok: false, error: "Manual settings could not be saved" }; }
      });
    }
  }
  const api = { ConfigSync, instagram, replyConfig, effective, summary };
  root.PetConfigSync = api;
  if (typeof module !== "undefined") module.exports = api;
})(globalThis);
