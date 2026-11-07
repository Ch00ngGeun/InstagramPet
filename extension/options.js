(() => {
  "use strict";
  const $ = id => document.getElementById(id), C = PetCommon;
  const feedback = (text, error = false) => { $("feedback").textContent = text; $("feedback").style.color = error ? "#be4c4c" : ""; };
  function request(type, extra = {}) {
    return new Promise((resolve, reject) => chrome.runtime.sendMessage({ type, ...extra }, result => {
      if (chrome.runtime.lastError) reject(new Error(chrome.runtime.lastError.message));
      else if (!result) reject(new Error("No worker response"));
      else resolve(result);
    }));
  }
  function showAppConfig(value) {
    const app = value.appConfig || {};
    $("appConfigNotice").textContent = app.managed
      ? `${app.disabled ? "Instagram is disabled by the pet app's blank selection." : "The pet app's Instagram selection takes priority."} Manual usernames and bindings below are preserved; they resume when app management is turned off. Enable observation must remain on. App changes normally sync within 5 seconds (one-minute recovery after worker suspension).${app.state === "unavailable" ? " The app could not be refreshed; the last valid selection remains applied." : ""}`
      : app.state === "unavailable"
        ? "The pet app could not be refreshed. The last valid/manual settings remain applied. Check the installed native bridge."
        : "Manual inputs below are active. You can also choose Instagram in the pet app's Settings window; app settings then take priority.";
  }
  function showBridge(value) {
    const bridge = value.bridge || {};
    $("status").textContent = JSON.stringify({ state: bridge.state || "not-tested", pendingExtensionEvents: value.pending || 0,
      ...(bridge.appInstalled !== undefined ? { appInstalled: bridge.appInstalled, nativeQueueDepth: bridge.queueDepth } : {}),
      ...(bridge.error ? { error: bridge.error } : {}), ...(bridge.at ? { checkedAt: new Date(bridge.at).toLocaleString() } : {}) }, null, 2);
  }
  async function refresh() {
    try {
      const value = await request("pet.status"); showBridge(value); showAppConfig(value);
      const active = Object.entries(value.diagnostics).filter(([, v]) => Date.now() - v.at < 120000);
      $("diagnostics").textContent = active.length ? JSON.stringify(Object.fromEntries(active), null, 2) : "No recent DM-page heartbeat. Open/reload a logged-in Instagram DM page.";
    } catch (error) { $("status").textContent = error.message; }
  }
  async function loadInputs() {
    await request("pet.config.sync").catch(() => {});
    const data = await chrome.storage.local.get(["settings", "manualSettings"]);
    const cfg = C.settings(data.manualSettings || data.settings);
    $("enabled").checked = cfg.enabled; $("senders").value = cfg.allowedSenders.join("\n");
    $("bindings").value = Object.entries(cfg.bindings).map(([key, val]) => `${key} = ${val}`).join("\n");
    $("confirmed").checked = Object.keys(cfg.bindings).length > 0; $("debug").checked = cfg.debug;
    $("selectors").value = JSON.stringify(cfg.selectors, null, 2);
    await refresh();
  }
  loadInputs().catch(() => feedback("Settings could not be loaded", true));
  $("extensionId").textContent = chrome.runtime.id;
  $("save").addEventListener("click", async () => {
    try {
      const allowedSenders = $("senders").value.split(/[\n,]+/).map(s => s.trim()).filter(Boolean).map(s => {
        const name = C.username(s); if (!name) throw new Error(`Invalid username: ${s}`); return name;
      });
      if (allowedSenders.length > 100) throw new Error("At most 100 senders");
      const bindings = {};
      for (const line of $("bindings").value.split("\n").map(s => s.trim()).filter(Boolean)) {
        const match = line.match(/^([A-Za-z0-9_-]{1,128})\s*=\s*(@?[a-z0-9._]{1,30})$/i);
        if (!match) throw new Error("Each binding must be THREAD_ID = username");
        bindings[match[1]] = C.username(match[2]);
      }
      if (Object.keys(bindings).length && !$("confirmed").checked) throw new Error("Confirm the one-to-one conversation identities first");
      const selectors = JSON.parse($("selectors").value || "{}");
      if (!selectors || Array.isArray(selectors) || typeof selectors !== "object") throw new Error("Selectors must be a JSON object");
      for (const [key, value] of Object.entries(selectors)) {
        if (!C.SELECTOR_KEYS.has(key) || typeof value !== "string" || value.length > 400) throw new Error(`Invalid selector setting: ${key}`);
        document.querySelector(value); // Syntax validation only; does not promise compatibility.
      }
      const result = await request("pet.settings.save", { settings: C.settings({ enabled: $("enabled").checked, allowedSenders, bindings, selectors, debug: $("debug").checked }) });
      if (!result.ok) throw new Error("Settings could not be saved");
      feedback(result.managed ? "Manual inputs saved. The pet app's selection still takes priority." : "Saved. Changed observations are now a fresh baseline."); refresh();
    } catch (error) { feedback(error.message, true); }
  });
  for (const [id, type] of [["ping", "pet.ping"], ["test", "pet.test"], ["clear", "pet.clear"]]) {
    $(id).addEventListener("click", async () => {
      $(id).disabled = true;
      try {
        const result = await request(type);
        if (!result.ok) throw new Error(result.error || result.bridge?.error || "Bridge request failed");
        feedback(id === "test" ? (result.pending ? "Test queued; bridge is unavailable. Check status." : "Test accepted by the native host; check the pet.") : id === "clear" ? "Pending messages and diagnostics cleared." : "Native host answered.");
        await refresh();
      } catch (error) { feedback(error.message, true); }
      finally { $(id).disabled = false; }
    });
  }
  refresh(); setInterval(refresh, 5000);
})();
