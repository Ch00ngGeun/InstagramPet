/* 네이티브 호스트에서 펫 앱의 Instagram 선택을 받아 사용자의 수동 설정 위에 적용한다.
   수동 설정은 따로 보관해 두었다가 앱 관리가 꺼지면 되돌린다. */
(function (root) {
  "use strict";
  const C = root.PetCommon || require("./common.js");
  const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
  const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  const selection = value => {
    const settings = C.settings(value);
    return [settings.enabled, settings.allowedSenders, settings.bindings];
  };
  function dropObsoletePending(data, desired, changes, now) {
    if (equal(selection(data.settings), selection(desired))) return;
    const allowed = C.settings(desired).allowedSenders;
    if (!allowed.length || !Array.isArray(data.pending)) return;
    const pending = data.pending.filter(item => item?.event?.kind === "test" || allowed.includes(item?.event?.sender));
    if (pending.length !== data.pending.length) {
      changes.pending = pending;
      changes.lastDrop = { reason: "selection-changed", at: now };
    }
  }

  function instagram(value) {
    if (value === null) return null; // 앱 지정 없음: 수동 설정을 유지한다.
    if (!value || typeof value !== "object" || Array.isArray(value)
        || Object.keys(value).sort().join(",") !== "threadId,username"
        || typeof value.username !== "string" || typeof value.threadId !== "string") throw new Error("Invalid app Instagram configuration");
    const { username, threadId } = value;
    if (!username && !threadId) return { username: "", threadId: "" };
    // 호스트는 정규화된 CSV를 주며, 사용자 이름마다 같은 순서로 스레드가 하나씩 대응한다.
    // 실제 적용 중인 선택을 조금이라도 바꾸기 전에 모든 항목을 검증한다.
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
          // 호스트는 Instagram 선택만 돌려준다. 원본 응답은 절대 저장하지 않는다.
          const app = replyConfig(await this.nativeRequest({ version: 1, type: "config" }));
          const data = await this.get(["settings", "manualSettings", "appInstagram", "appConfigSync", "pending"]);
          const manual = C.settings(data.manualSettings || data.settings);
          const desired = effective(manual, app), changes = {};
          // 적용 값을 바꾸기 전에 편집 가능한 원래 선택부터 보존한다.
          // 이 쓰기가 실패하면 현재 적용 중인 선택은 건드리지 않는다.
          if (app !== null && !data.manualSettings) await this.set({ manualSettings: manual });
          if (!equal(data.settings, desired)) changes.settings = desired;
          dropObsoletePending(data, desired, changes, this.now());
          if (!own(data, "appInstagram") || !equal(data.appInstagram, app)) changes.appInstagram = app;
          const state = app === null ? "manual" : "managed";
          if (data.appConfigSync?.state !== state || own(changes, "settings") || own(changes, "appInstagram"))
            changes.appConfigSync = { state, at: this.now() };
          if (Object.keys(changes).length) await this.set(changes);
          return { ok: true, ...summary({ ...data, ...changes }) };
        } catch {
          // 호스트가 없거나 오래됐거나 응답이 잘못되면 마지막 유효 선택을 그대로 둔다.
          let data = {};
          try {
            data = await this.get(["appInstagram", "appConfigSync"]);
            if (data.appConfigSync?.state !== "unavailable") await this.set({ appConfigSync: { state: "unavailable", at: this.now() } });
          } catch { /* 저장소 오류가 제공자 메시지나 설정 값을 그대로 노출하면 안 된다. */ }
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
          dropObsoletePending(data, desired, changes, this.now());
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
