importScripts("common.js", "worker-core.js");
"use strict";
const HOST = "com.instagrampet.bridge";
let port = null, inflight = null;
function nativeRequest(message) {
  return new Promise((resolve, reject) => {
    if (inflight) { reject(new Error("Native request already active")); return; }
    let timeout;
    const complete = (error, reply) => {
      clearTimeout(timeout); inflight = null;
      if (error) reject(error); else resolve(reply);
    };
    try {
      if (!port) {
        const connection = chrome.runtime.connectNative(HOST);
        port = connection;
        connection.onMessage.addListener(reply => {
          if (!inflight || connection !== port) return;
          if (reply?.type === "error") inflight(new Error(reply.error || "Host rejected request"));
          else inflight(null, reply);
        });
        connection.onDisconnect.addListener(() => {
          const message = chrome.runtime.lastError?.message || "Native host disconnected";
          if (connection !== port) return;
          port = null;
          if (inflight) inflight(new Error(message));
        });
      }
      inflight = complete;
      timeout = setTimeout(() => {
        const connection = port; port = null;
        complete(new Error("Native host timed out"));
        try { connection?.disconnect(); } catch { /* Already closed. */ }
      }, 8000);
      port.postMessage(message);
    } catch (error) { complete(error); port = null; }
  });
}
const queue = new PetWorker.BridgeQueue({
  get: keys => chrome.storage.local.get(keys),
  set: values => chrome.storage.local.set(values), nativeRequest
});
function fromContent(sender) {
  if (sender.id !== chrome.runtime.id || !sender.tab || sender.frameId !== 0) return false;
  try {
    const url = new URL(sender.url);
    return url.protocol === "https:" && ["www.instagram.com", "instagram.com"].includes(url.hostname) && !url.port;
  } catch { return false; }
}
function fromUI(sender) {
  return sender.id === chrome.runtime.id && ["options.html", "popup.html"].some(path => sender.url === chrome.runtime.getURL(path));
}
async function handle(message, sender) {
  if (!message || typeof message.type !== "string") throw new Error("Invalid request");
  if (fromContent(sender)) {
    if (message.type === "pet.observation") {
      if (!/^\/direct(?:\/|$)/.test(new URL(sender.url).pathname)) throw new Error("Observation requires a DM page");
      const answer = await queue.enqueue(message.event);
      queue.flush().catch(() => {});
      return answer;
    }
    if (message.type === "pet.diagnostics") {
      const info = message.info || {};
      const validStates = ["disabled", "no-allowlist", "open-dm-page", "invalid-selector", "observing", "unsupported-dom"];
      if (!validStates.includes(info.state)) throw new Error("Invalid diagnostics");
      const clean = { state: info.state, page: ["thread", "inbox", "other"].includes(info.page) ? info.page : "other", at: Date.now() };
      for (const key of ["scans", "observations", "sendErrors", "inboxRows", "messageRows", "unknownSender", "ambiguousSender", "ambiguousText", "dropped", "contentPending"]) clean[key] = Math.min(1e9, Math.max(0, Number(info[key]) || 0));
      clean.invalidSelector = info.invalidSelector === true;
      clean.capped = info.capped === true;
      const data = await chrome.storage.local.get("diagnostics"), now = Date.now();
      const diagnostics = Object.fromEntries(Object.entries(data.diagnostics || {}).filter(([, v]) => now - v.at < 120000).slice(-15));
      diagnostics[String(sender.tab.id)] = clean;
      await chrome.storage.local.set({ diagnostics });
      return { ok: true };
    }
    throw new Error("Unsupported content request");
  }
  if (!fromUI(sender)) throw new Error("Untrusted sender");
  if (message.type === "pet.status") {
    const data = await chrome.storage.local.get(["pending", "diagnostics", "bridge", "lastDrop"]);
    return { ok: true, pending: data.pending?.length || 0, diagnostics: data.diagnostics || {}, bridge: data.bridge || { state: "not-tested" }, lastDrop: data.lastDrop };
  }
  if (message.type === "pet.ping") { const reply = await queue.ping(); queue.flush().catch(() => {}); return reply; }
  if (message.type === "pet.test") {
    const now = Date.now();
    const event = { version: 1, type: "dm", eventId: `test:${crypto.randomUUID()}`, sender: "demo.pet", displayName: "Bridge test", text: "Hello! Chrome → Swift 연결 테스트입니다.", threadUrl: "https://www.instagram.com/direct/t/demo/", observedAt: new Date(now).toISOString(), kind: "test" };
    await queue.enqueue(event, true);
    return { ok: true, ...(await queue.flush()) };
  }
  if (message.type === "pet.clear") { await queue.exclusive(() => chrome.storage.local.remove(["pending", "diagnostics", "lastDrop"])); return { ok: true }; }
  throw new Error("Unsupported UI request");
}
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  handle(message, sender).then(sendResponse).catch(error => sendResponse({ ok: false, error: PetCommon.clip(error.message, 250) }));
  return true; // Keep the callback channel open, including Chrome before Promise responses.
});
function ensureAlarm() { chrome.alarms.create("pet-retry", { periodInMinutes: 1 }); }
chrome.runtime.onInstalled.addListener(() => { ensureAlarm(); queue.flush().catch(() => {}); });
chrome.runtime.onStartup.addListener(() => { ensureAlarm(); queue.flush().catch(() => {}); });
chrome.alarms.onAlarm.addListener(alarm => { if (alarm.name === "pet-retry") queue.flush().catch(() => {}); });
chrome.storage.onChanged.addListener((changes, area) => { if (area === "local" && changes.settings) queue.flush().catch(() => {}); });
ensureAlarm();
