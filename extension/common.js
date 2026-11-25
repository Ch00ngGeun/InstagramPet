/* 격리된 콘텐츠 스크립트, 옵션 페이지, 서비스 워커, 테스트가 함께 쓰는 공통 함수. */
(function (root) {
  "use strict";
  const DEFAULTS = Object.freeze({
    enabled: true, allowedSenders: [], bindings: {}, selectors: {}, debug: false
  });
  const SELECTOR_KEYS = new Set([
    "inboxRow", "inboxUnread", "inboxPreview", "messageRow", "incomingMessage",
    "outgoingMessage", "messageText", "threadRoot"
  ]);
  function username(value) {
    if (typeof value !== "string") return null;
    const result = value.trim().replace(/^@/, "").toLowerCase();
    return /^[a-z0-9._]{1,30}$/.test(result) && !/[\r\n]/.test(result) ? result : null;
  }
  function clip(value, max) { return Array.from(String(value || "")).slice(0, max).join(""); }
  function threadURL(value) {
    try {
      const url = new URL(value, "https://www.instagram.com");
      const match = url.pathname.match(/^\/direct\/t\/([A-Za-z0-9_-]{1,128})\/?$/);
      if (url.protocol !== "https:" || !["instagram.com", "www.instagram.com"].includes(url.hostname) || url.port || url.search || url.hash || !match) return null;
      return { id: match[1], url: `https://www.instagram.com/direct/t/${match[1]}/` };
    } catch { return null; }
  }
  function settings(raw = {}) {
    const result = { ...DEFAULTS, enabled: raw.enabled !== false, debug: raw.debug === true };
    result.allowedSenders = [...new Set((Array.isArray(raw.allowedSenders) ? raw.allowedSenders : []).map(username).filter(Boolean))].slice(0, 100);
    result.bindings = {};
    for (const [key, val] of Object.entries(raw.bindings || {}).slice(0, 100)) {
      if (/^[A-Za-z0-9_-]{1,128}$/.test(key) && username(val)) result.bindings[key] = username(val);
    }
    result.selectors = {};
    for (const [key, val] of Object.entries(raw.selectors || {})) {
      if (SELECTOR_KEYS.has(key) && typeof val === "string" && val.trim().length <= 400) result.selectors[key] = val.trim();
    }
    return result;
  }
  // 독립된 32비트 해시 두 개: 관찰 식별용 결정적 값일 뿐, 보안용이 아니다.
  function hash(value) {
    let a = 2166136261, b = 0x9e3779b9;
    for (const c of String(value)) {
      const n = c.codePointAt(0);
      a = Math.imul(a ^ n, 16777619);
      b = Math.imul(b ^ n, 2246822519);
    }
    return (a >>> 0).toString(16).padStart(8, "0") + (b >>> 0).toString(16).padStart(8, "0");
  }
  const api = { DEFAULTS, SELECTOR_KEYS, username, clip, threadURL, settings, hash };
  root.PetCommon = api;
  if (typeof module !== "undefined") module.exports = api;
})(globalThis);
