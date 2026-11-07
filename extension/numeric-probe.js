(() => {
  'use strict';
  // Apple Events JavaScript runs outside the privileged extension world. Only this
  // options page bridges its two explicit diagnostic commands through the DOM.
  let busy = false;
  const root = document.documentElement;
  root.addEventListener('pet-numeric-probe', async () => {
    if (busy) return;
    const command = root.getAttribute('data-pet-numeric-command');
    if (!['tabs', 'reload'].includes(command)) return;
    busy = true;
    const answer = value => root.setAttribute('data-pet-numeric-result', JSON.stringify(value));
    try {
      if (command === 'reload') {
        answer({ ready: 1, reloadScheduled: 1 });
        queueMicrotask(() => chrome.runtime.reload());
        return;
      }
      const [tabs, state, allTabs, local] = await Promise.all([
        chrome.tabs.query({ url: ['https://www.instagram.com/*', 'https://instagram.com/*'] }),
        chrome.storage.session.get('petRetainedTabs'), chrome.tabs.query({}),
        chrome.storage.local.get(['settings', 'diagnostics', 'manualSettings', 'appInstagram', 'appConfigSync'])
      ]);
      const direct = tabs.filter(tab => {
        try { return /^\/direct(?:\/|$)/.test(new URL(tab.url).pathname); }
        catch { return false; }
      });
      const directIds = new Set(direct.map(tab => tab.id));
      const recent = Object.entries(local.diagnostics || {})
        .filter(([id, row]) => directIds.has(Number(id)) && Date.now() - row.at < 120000).map(([, row]) => row);
      answer({ ready: 1, totalTabs: allTabs.length - 1, directTabs: direct.length,
        observationEnabled: local.settings?.enabled === false ? 0 : 1,
        allowedSenders: Array.isArray(local.settings?.allowedSenders) ? local.settings.allowedSenders.length : 0,
        manualAllowedSenders: Array.isArray(local.manualSettings?.allowedSenders)
          ? local.manualSettings.allowedSenders.length : (Array.isArray(local.settings?.allowedSenders) ? local.settings.allowedSenders.length : 0),
        manualBindings: Object.keys(local.manualSettings?.bindings || local.settings?.bindings || {}).length,
        appConfigManaged: local.appInstagram != null ? 1 : 0,
        appConfigDisabled: local.appInstagram?.username === '' ? 1 : 0,
        appConfigSynced: ['manual', 'managed'].includes(local.appConfigSync?.state) ? 1 : 0,
        appConfigUnavailable: local.appConfigSync?.state === 'unavailable' ? 1 : 0,
        recentDiagnosticTabs: recent.length, observingTabs: recent.filter(row => row.state === 'observing').length,
        pinned: direct.filter(tab => tab.pinned).length,
        autoDiscardDisabled: direct.filter(tab => tab.autoDiscardable === false).length,
        discarded: direct.filter(tab => tab.discarded).length, frozen: direct.filter(tab => tab.frozen).length,
        retained: Array.isArray(state.petRetainedTabs) ? state.petRetainedTabs.length : 0 });
    } catch { answer({ ready: 1, queryError: 1 }); }
    finally { busy = false; }
  });
})();
