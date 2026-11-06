(() => {
  "use strict";
  const $ = id => document.getElementById(id), C = PetCommon;
  const feedback = (text, error = false) => { $("feedback").textContent = text; $("feedback").style.color = error ? "#be4c4c" : ""; };
  function request(type) {
    return new Promise((resolve, reject) => chrome.runtime.sendMessage({ type }, result => {
      if (chrome.runtime.lastError) reject(new Error(chrome.runtime.lastError.message));
      else if (!result) reject(new Error("No worker response"));
      else resolve(result);
    }));
  }
  function showBridge(value) {
    const bridge = value.bridge || {};
    $("status").textContent = JSON.stringify({ state: bridge.state || "not-tested", pendingExtensionEvents: value.pending || 0,
      ...(bridge.appInstalled !== undefined ? { appInstalled: bridge.appInstalled, nativeQueueDepth: bridge.queueDepth } : {}),
      ...(bridge.error ? { error: bridge.error } : {}), ...(bridge.at ? { checkedAt: new Date(bridge.at).toLocaleString() } : {}) }, null, 2);
  }
  async function refresh() {
    try {
      const value = await request("pet.status"); showBridge(value);
      const active = Object.entries(value.diagnostics).filter(([, v]) => Date.now() - v.at < 120000);
      $("diagnostics").textContent = active.length ? JSON.stringify(Object.fromEntries(active), null, 2) : "No recent DM-page heartbeat. Open/reload a logged-in Instagram DM page.";
    } catch (error) { $("status").textContent = error.message; }
  }
  chrome.storage.local.get("settings", data => {
    const cfg = C.settings(data.settings);
    $("enabled").checked = cfg.enabled; $("senders").value = cfg.allowedSenders.join("\n");
    $("bindings").value = Object.entries(cfg.bindings).map(([key, val]) => `${key} = ${val}`).join("\n");
    $("confirmed").checked = Object.keys(cfg.bindings).length > 0; $("debug").checked = cfg.debug;
    $("selectors").value = JSON.stringify(cfg.selectors, null, 2);
  });
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
      await chrome.storage.local.set({ settings: C.settings({ enabled: $("enabled").checked, allowedSenders, bindings, selectors, debug: $("debug").checked }) });
      feedback("Saved. Existing messages are now a fresh baseline."); refresh();
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
