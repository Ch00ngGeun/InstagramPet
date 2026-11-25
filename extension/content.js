// Instagram 페이지의 콘텐츠 스크립트: DOM이 바뀔 때마다 검사해 새 DM 관찰,
// 읽음 표시, 진단 신호를 서비스 워커로 보낸다.
(() => {
  "use strict";
  const C = PetCommon, D = PetDetector;
  const tracker = new D.Tracker(), outbox = new Map();
  let readSent = false, config = C.settings(), scheduled = false, lastPath = "", lastScan = 0, stopped = false, lastDiagnostic = 0, running = false, rerun = false;
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
    if (stopped || scheduled) return;
    scheduled = true;
    // 변경은 이미 묶음으로 들어온다. 실제 DOM 변화를 백그라운드 탭 타이머 뒤로 미루지 않는다.
    // Chrome은 그 타이머를 초나 분 단위로 맞춰 늦출 수 있다.
    queueMicrotask(() => { scheduled = false; scan(); });
  }
  async function scan() {
    if (stopped) return;
    if (running) { rerun = true; return; }
    running = true;
    try {
      const now = Date.now(), path = location.pathname;
      // 렌더러가 오래 멈췄던 건 공백일 뿐, 지난 대화를 새로 알릴 이유가 아니다.
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
          readSent = false; // 사용자가 이 스레드를 보는 중에 온 새 메시지도 읽음으로 처리한다
        }
        while (outbox.size > 50) { outbox.delete(outbox.keys().next().value); metadata.dropped++; }
        for (const [id, event] of outbox) {
          if (now - Date.parse(event.observedAt) > 300000) { outbox.delete(id); metadata.dropped++; continue; }
          const response = await send({ type: "pet.observation", event });
          // 워커가 저장했거나 중복으로 판정한 경우에만 임시 보낼함에서 뺀다.
          if (response?.ok) outbox.delete(id);
          else break;
        }
      } else { tracker.reset(); outbox.clear(); }
      // 사용자가 포커스된 창에서 이 스레드를 보고 있다: 해당 펫 말풍선은 없애도 된다.
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
  const poll = setInterval(schedule, 5000); // SPA 이동과 놓친 렌더러 갱신 대비. Chrome이 이 주기를 늦출 수 있다.
  addEventListener("pageshow", event => { if (event.persisted) tracker.reset(); schedule(); });
  addEventListener("pagehide", () => tracker.reset());
  addEventListener("focus", schedule);
  addEventListener("blur", schedule);
  document.addEventListener("visibilitychange", schedule);
  document.addEventListener("resume", schedule);
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && changes.settings) { config = C.settings(changes.settings.newValue); tracker.reset(); outbox.clear(); schedule(); }
  });
  chrome.storage.local.get("settings", result => { config = C.settings(result.settings); schedule(); });
})();
