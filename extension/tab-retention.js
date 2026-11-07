(function (root) {
  'use strict';
  const MATCHES = ['https://www.instagram.com/*', 'https://instagram.com/*'];
  function isDirect(value) {
    try {
      const url = new URL(value);
      return url.protocol === 'https:' && !url.port && ['www.instagram.com', 'instagram.com'].includes(url.hostname)
        && /^\/direct(?:\/|$)/.test(url.pathname);
    } catch { return false; }
  }
  // Persist only tab IDs and their prior boolean in session storage. A service-worker
  // restart must not lose the ability to restore a tab after it leaves the DM page.
  class TabRetention {
    constructor(chrome) { this.chrome = chrome; this.serial = Promise.resolve(); }
    run(operation) {
      const job = this.serial.then(async () => {
        const data = await this.chrome.storage.session.get('petRetainedTabs');
        const state = new Map((Array.isArray(data.petRetainedTabs) ? data.petRetainedTabs : [])
          .filter(row => Array.isArray(row) && Number.isInteger(row[0]) && typeof row[1] === 'boolean'));
        const { settings } = await this.chrome.storage.local.get('settings');
        const config = root.PetCommon.settings(settings);
        await operation(state, config.enabled && config.allowedSenders.length > 0);
        await this.chrome.storage.session.set({ petRetainedTabs: [...state] });
      });
      this.serial = job.catch(() => {});
      return job;
    }
    async update(tab, enabled, state) {
      if (!Number.isInteger(tab?.id)) return;
      if (enabled && isDirect(tab.url)) {
        const original = state.has(tab.id) ? state.get(tab.id) : tab.autoDiscardable !== false;
        if (tab.autoDiscardable !== false) await this.chrome.tabs.update(tab.id, { autoDiscardable: false });
        state.set(tab.id, original);
      } else if (state.has(tab.id)) {
        const original = state.get(tab.id);
        if (tab.autoDiscardable !== original) await this.chrome.tabs.update(tab.id, { autoDiscardable: original });
        state.delete(tab.id);
      }
    }
    refresh() {
      return this.run(async (state, enabled) => {
        const tabs = await this.chrome.tabs.query({ url: MATCHES });
        const found = new Set(tabs.map(tab => tab.id));
        for (const id of state.keys()) if (!found.has(id)) {
          try { tabs.push(await this.chrome.tabs.get(id)); }
          catch { state.delete(id); }
        }
        for (const tab of tabs) await this.update(tab, enabled, state);
      });
    }
    changed(id, change, tab) {
      if (!change.url && change.status !== 'complete') return Promise.resolve();
      return this.run(async (state, enabled) => {
        try {
          const current = tab || await this.chrome.tabs.get(id);
          await this.update({ ...current, id, url: change.url || current.url }, enabled, state);
        } catch { /* A tab can close while navigation is being handled. */ }
      });
    }
    removed(id) { return this.run(state => { state.delete(id); }); }
  }
  root.PetTabRetention = { TabRetention, isDirect };
  if (typeof module !== 'undefined') module.exports = root.PetTabRetention;
})(globalThis);
