// 관찰이 켜져 있는 동안 Instagram DM 탭의 Chrome 자동 탭 정리를 끄고 등록된 대화방마다 고정된 DM 탭을 유지하며,
// 관찰이 끝나면 각 탭의 자동 정리 설정을 원래대로 되돌린다.
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
  // 세션 저장소에는 탭 ID와 원래 불리언 값만 보관한다. 서비스 워커가 다시 시작돼도
  // 탭이 DM 페이지를 벗어난 뒤 원래대로 되돌릴 수 있어야 한다.
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
        } catch { /* 이동을 처리하는 사이 탭이 닫힐 수 있다. */ }
      });
    }
    removed(id) { return this.run(state => { state.delete(id); }); }
    // 관찰 중에는 등록된 대화방(bindings)마다 고정된 탭이 하나씩 있게 한다. 실제 화면에서는 목록(inbox)
    // 미리보기로 감지할 수 없어 대화방 탭이 필요하다(docs/DOM-DRIFT.md). 그 대화방 탭이 있으면 고정만 하고,
    // 없으면 뒤에서 새로 열어 고정한다. 우리가 연 탭이 로그인 화면 등으로 바뀌어도 닫히기 전에는 다시
    // 열지 않는다(1분마다 탭이 늘지 않게).
    ensurePinned() {
      return this.run(async (state, enabled) => {
        if (!enabled) return;
        const C = root.PetCommon, { settings } = await this.chrome.storage.local.get('settings');
        const threads = Object.keys(C.settings(settings).bindings);
        if (!threads.length) return;
        const tabs = await this.chrome.tabs.query({ url: MATCHES });
        const { petOpenedTabs } = await this.chrome.storage.session.get('petOpenedTabs');
        const opened = petOpenedTabs && typeof petOpenedTabs === 'object' ? petOpenedTabs : {}, next = {};
        let window;
        for (const id of threads) {
          const mine = tabs.filter(tab => C.threadURL(tab.url || tab.pendingUrl || '')?.id === id);
          if (mine.some(tab => tab.pinned)) continue;
          if (mine.length) { await this.chrome.tabs.update(mine[0].id, { pinned: true }); continue; }
          if (Number.isInteger(opened[id])) {
            try { await this.chrome.tabs.get(opened[id]); next[id] = opened[id]; continue; } catch { /* 닫혔다: 새로 연다. */ }
          }
          window = window || (await this.chrome.windows.getAll({ windowTypes: ['normal'] }))[0];
          if (!window) return; // 크롬 창이 하나도 없으면 창을 억지로 띄우지 않는다.
          const tab = await this.chrome.tabs.create({ windowId: window.id, url: `https://www.instagram.com/direct/t/${id}/`, active: false, pinned: true });
          next[id] = tab.id;
        }
        await this.chrome.storage.session.set({ petOpenedTabs: next });
      });
    }
  }
  root.PetTabRetention = { TabRetention, isDirect };
  if (typeof module !== 'undefined') module.exports = root.PetTabRetention;
})(globalThis);
