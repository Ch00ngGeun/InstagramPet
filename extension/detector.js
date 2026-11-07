(function (root) {
  "use strict";
  const C = root.PetCommon || require("./common.js");
  const RESERVED = new Set(["direct", "explore", "accounts", "reels", "p", "stories", "about", "legal", "privacy", "developer", "notifications"]);
  const INCOMING = /^(?:message from|message sent by|sent by|보낸 사람|메시지를 보낸 사람)\s*[:：]?\s*(@?[a-z0-9._]{1,30})(?=\s|:|：|$)/i;
  const OUTGOING = /^(?:you(?: sent|:)|(?:message )?sent by you|message from you(?:\s|:|$)|내가 보낸|회원님이 보낸|나:)/i;
  // Live Korean UI (verified 2026-11-06): each message's action buttons read "<username>님의 메시지에 답장하기".
  const ACTION = /^@?([a-z0-9._]{1,30})님의 메시지에/i;
  const ROWS = "[role='row'], [data-message-id], [data-item-id], [role='group'][tabindex='-1']";
  const UNREAD = /(?:\bunread\b|읽지 않|안 읽은|未読|未讀)/i;
  const SPACE = /\s+/g;
  function text(node) { return (node?.textContent || "").replace(SPACE, " ").trim(); }
  function label(node) { return (node?.getAttribute?.("aria-label") || "").trim(); }
  function query(node, selector, diagnostics) {
    try { const nodes = Array.from(node.querySelectorAll(selector)); if (nodes.length > 500) diagnostics.capped = true; return nodes.slice(-500); }
    catch { diagnostics.invalidSelector = true; return []; }
  }
  function matches(node, selector, diagnostics) {
    if (!selector) return false;
    try { return node.matches(selector); } catch { diagnostics.invalidSelector = true; return false; }
  }
  function visible(node) {
    return !node.closest("[hidden], [aria-hidden='true'], script, style, template");
  }
  function profileUsers(node, diagnostics) {
    const found = new Set();
    for (const a of query(node, "a[href]", diagnostics)) {
      try {
        const u = new URL(a.getAttribute("href"), "https://www.instagram.com");
        const match = u.pathname.match(/^\/([a-z0-9._]{1,30})\/?$/i);
        if (u.protocol === "https:" && ["instagram.com", "www.instagram.com"].includes(u.hostname) && match && !RESERVED.has(match[1].toLowerCase())) found.add(C.username(match[1]));
      } catch { /* Ignore malformed page links. */ }
    }
    return [...found].filter(Boolean);
  }
  function resolveSender(node, binding, diagnostics, senderOnly = false) {
    // Display names and body mentions are not account identifiers. In a message row,
    // a profile URL counts only when it wraps a profile-picture image; direction is
    // established separately. A user-confirmed 1:1 binding is the usual fallback.
    const users = senderOnly ? query(node, "a[href]", diagnostics).filter(a =>
      query(a, "img[alt]", diagnostics).some(img => /profile picture|프로필 사진/i.test(img.getAttribute("alt") || ""))
    ).flatMap(a => profileUsers(a.parentElement, diagnostics).filter(user => {
      try { return new URL(a.getAttribute("href"), "https://www.instagram.com").pathname.replace(/^\/|\/$/g, "").toLowerCase() === user; }
      catch { return false; }
    })) : profileUsers(node, diagnostics);
    const handle = label(node).match(INCOMING)?.[1];
    if (senderOnly && handle?.startsWith("@")) users.push(C.username(handle));
    const unique = [...new Set(users.filter(Boolean))];
    if (unique.length > 1 || (unique.length === 1 && binding && unique[0] !== binding)) {
      diagnostics.ambiguousSender++;
      return null;
    }
    return unique[0] || binding || null;
  }
  function stripPreview(value, sender) {
    return value.replace(new RegExp(`^@?${sender.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s*[:：]\\s*`, "i"), "").trim();
  }
  function unreadEvidence(row, config, diagnostics) {
    if (UNREAD.test(label(row))) return true;
    if (query(row, "[aria-label], [title]", diagnostics).some(n => UNREAD.test(label(n) + " " + n.getAttribute("title")))) return true;
    return config.selectors.inboxUnread && query(row, config.selectors.inboxUnread, diagnostics).length > 0;
  }
  function previewText(row, config, diagnostics) {
    if (config.selectors.inboxPreview) return text(query(row, config.selectors.inboxPreview, diagnostics)[0]);
    // Prefer an accessibility description of the preview over an arbitrary row's entire text.
    const describedBy = row.getAttribute("aria-describedby");
    if (describedBy) {
      const parts = describedBy.split(/\s+/).map(id => row.ownerDocument.getElementById(id)).filter(Boolean);
      if (parts.length) return parts.map(text).join(" ");
    }
    // Instagram often renders sender + preview as separate dir=auto runs. This is an
    // intentionally conservative fallback: reject a row with no separate text run.
    const runs = query(row, "[dir='auto']", diagnostics).filter(n => !n.querySelector("[dir='auto']")).map(text).filter(Boolean);
    return runs.length >= 2 ? runs[runs.length - 1] : "";
  }
  function inbox(document, config, diagnostics) {
    const links = query(document, config.selectors.inboxRow || "a[href*='/direct/t/'], [role='link'][href*='/direct/t/']", diagnostics);
    const seen = new Set(), result = [];
    for (const row of links) {
      if (!visible(row)) continue;
      const link = row.hasAttribute("href") ? row : query(row, "a[href*='/direct/t/']", diagnostics)[0];
      const thread = C.threadURL(link?.getAttribute("href"));
      if (!thread || seen.has(thread.id)) continue;
      seen.add(thread.id);
      const sender = resolveSender(row, config.bindings[thread.id], diagnostics);
      const raw = previewText(row, config, diagnostics);
      const preview = sender ? stripPreview(raw, sender) : raw;
      const timeNode = query(row, "time[datetime]", diagnostics)[0];
      const timestamp = timeNode?.getAttribute("datetime") || "";
      const outgoing = OUTGOING.test(preview) || OUTGOING.test(label(row));
      result.push({ thread: thread.id, threadUrl: thread.url, sender, text: C.clip(preview, 2000),
        unread: !!unreadEvidence(row, config, diagnostics), outgoing, timestamp,
        // No promise of exact repeat detection when the inbox preview has no server timestamp.
        signature: C.hash([sender, preview, timestamp, outgoing].join("\u001f")) });
      diagnostics.inboxRows++;
      if (!sender) diagnostics.unknownSender++;
    }
    return result;
  }
  const EMOJI_ONLY = /^[\p{Extended_Pictographic}\p{Emoji_Component}\u200d\ufe0f\s]+$/u;
  // Live Korean UI (2026-11-06): emoji-only bubbles have no dir=auto run; shared reels/posts are a
  // button with thumbnail + author link, reels add an svg labelled "클립", story shares link /stories/.
  // DM photos/videos are one button per item whose thumbnail alt names it ("사진…"/"동영상…").
  const VIDEO_ALT = /동영상|video/i, PHOTO_ALT = /사진|photo|image|이미지/i, PROFILE_ALT = /프로필|profile/i;
  function mediaItem(node, diagnostics) {
    const imgs = query(node, "img", diagnostics).filter(i => !PROFILE_ALT.test(i.getAttribute("alt") || ""));
    const alts = imgs.map(i => i.getAttribute("alt") || "");
    // Fresh live bubbles had empty alts: a video shows a static .png play glyph over a CDN thumbnail.
    const icon = imgs.some(i => /\.png(?:$|\?)/.test(i.getAttribute("src") || "")), thumbs = imgs.filter(i => !/\.png(?:$|\?)/.test(i.getAttribute("src") || ""));
    if (query(node, "video", diagnostics).length || alts.some(a => VIDEO_ALT.test(a)) || (icon && thumbs.length)) return "(동영상)";
    return alts.some(a => PHOTO_ALT.test(a)) || (!icon && thumbs.length === 1) ? "(이미지)" : null;
  }
  function media(body, diagnostics) {
    // Prefer a per-item link (story/reel/post IDs), else the thumbnail, so different shares don't collapse.
    const src = query(body, "a[href*='/stories/'], a[href*='/reel/'], a[href*='/p/']", diagnostics)[0]?.getAttribute("href") ||
      query(body, "video[src], img[src]", diagnostics).map(n => n.getAttribute("src")).find(v => !/\.png(?:$|\?)/.test(v)) || "";
    let key = ""; try { key = src && C.hash(new URL(src, "https://www.instagram.com").pathname); } catch { /* unusable src */ }
    const has = selector => query(body, selector, diagnostics).length > 0;
    if (has("svg[aria-label='클립'], svg[aria-label='Clip'], svg[aria-label='Reels'], a[href*='/reel/']")) return { label: "(릴스)", key };
    if (has("a[href*='/stories/']")) return { label: "(스토리)", key };
    if (has("[role='button'] img") && has("a[href]")) return { label: "(게시물)", key };
    const items = query(body, "[role='button']", diagnostics).filter(b => !b.parentElement.closest("[role='button']")).map(b => mediaItem(b, diagnostics)).filter(Boolean);
    const label = items.length ? items.join(" ") : mediaItem(body, diagnostics);
    if (label) return { label, key };
    const value = text(body);
    return value && EMOJI_ONLY.test(value) ? { label: value, key: "" } : null;
  }
  function actionSender(row, diagnostics) {
    const users = new Set(query(row, "[role='button'][aria-label]", diagnostics).map(b => label(b).match(ACTION)?.[1]).filter(Boolean).map(C.username));
    if (users.size > 1) diagnostics.ambiguousSender++;
    return users.size === 1 ? [...users][0] : null;
  }
  function isOutgoing(row, config, diagnostics) {
    return OUTGOING.test(label(row)) || (config.selectors.outgoingMessage && matches(row, config.selectors.outgoingMessage, diagnostics));
  }
  function thread(document, location, config, diagnostics) {
    const current = C.threadURL(location);
    if (!current) return null;
    const binding = config.bindings[current.id];
    const scope = config.selectors.threadRoot ? query(document, config.selectors.threadRoot, diagnostics)[0] : (document.querySelector("main") || document.querySelector("[role='main']"));
    if (!scope) return { id: current.id, url: current.url, rows: [], atBottom: false, supported: false };
    let rows = query(scope, config.selectors.messageRow || ROWS, diagnostics);
    // Avoid nested candidates and sidebar links: the deepest message row is the unit.
    const rowSet = new Set(rows);
    rows = rows.filter(n => visible(n) && !Array.from(n.querySelectorAll(ROWS)).some(x => rowSet.has(x)));
    const occurrences = new Map(), result = [];
    for (const row of rows) {
      if (query(row, "a[href*='/direct/t/']", diagnostics).length) continue;
      const actor = actionSender(row, diagnostics);
      // In a user-verified 1:1 thread, an action label naming anyone but the partner is the user's own message.
      const outgoing = !!isOutgoing(row, config, diagnostics) || (!!binding && !!actor && actor !== binding);
      const accessibleSender = label(row).match(INCOMING)?.[1];
      const incoming = !outgoing && (!!accessibleSender || !!actor || (config.selectors.incomingMessage && matches(row, config.selectors.incomingMessage, diagnostics)));
      const sender = incoming ? (actor || resolveSender(row, binding, diagnostics, true)) : null;
      let message = "", mediaKey = "";
      if (config.selectors.messageText) message = text(query(row, config.selectors.messageText, diagnostics)[0]);
      else {
        // The bubble body lives in role=article; names and time separators sit outside it.
        const body = query(row, "[role='article']", diagnostics)[0] || row;
        const texts = query(body, "[dir='auto']", diagnostics).filter(n => !n.querySelector("[dir='auto']") && !n.closest("a, button, [role='button']")).map(text).filter(Boolean);
        // Multiple text runs (e.g. message + reaction) are ambiguous; user may calibrate.
        if (texts.length === 1) message = texts[0];
        else if (!texts.length) { const found = media(body, diagnostics); if (found) { message = found.label; mediaKey = found.key; } }
      }
      const timeNode = query(row, "time[datetime]", diagnostics)[0];
      const timestamp = timeNode?.getAttribute("datetime") || "";
      const serverId = row.getAttribute("data-message-id") || row.getAttribute("data-item-id") || "";
      const fingerprint = C.hash([sender, outgoing ? "out" : incoming ? "in" : "unknown", message, mediaKey, timestamp].join("\u001f"));
      const occurrence = (occurrences.get(fingerprint) || 0) + 1;
      occurrences.set(fingerprint, occurrence);
      const key = serverId ? `id:${serverId}` : `fp:${fingerprint}:${occurrence}`;
      result.push({ key, node: row, sender, text: C.clip(message, 2000), incoming: !!incoming, outgoing, timestamp, serverId,
        threadUrl: current.url, thread: current.id });
      diagnostics.messageRows++;
      if (incoming && !sender) diagnostics.unknownSender++;
      if (incoming && !message) diagnostics.ambiguousText++;
    }
    const lastNode = rows[rows.length - 1];
    let scroll = lastNode?.parentElement;
    while (scroll && scroll !== document.body && scroll.scrollHeight <= scroll.clientHeight + 16) scroll = scroll.parentElement;
    // An unscrollable list is already at its tail; a virtualized scroller must be at bottom.
    // Live Instagram uses a column-reverse scroller: its bottom is scrollTop 0, negative when scrolled up.
    const reversed = !!scroll && /reverse/.test(document.defaultView?.getComputedStyle(scroll).flexDirection || "");
    const atBottom = !scroll || scroll.scrollHeight <= scroll.clientHeight + 16 ||
      (reversed ? Math.abs(scroll.scrollTop) < 100 : scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < 100);
    for (const item of result) {
      // Without a stable item ID or machine timestamp, identical repeated rows cannot
      // be separated safely from a history prepend/virtualization shift. Suppress them.
      const fingerprint = item.key.match(/^fp:([^:]+):/ )?.[1];
      item.ambiguousIdentity = !item.serverId && !item.timestamp && (occurrences.get(fingerprint) || 0) > 1;
    }
    return { id: current.id, url: current.url, rows: result, atBottom, supported: result.length > 0 };
  }
  function scan(document, location, rawConfig) {
    const config = C.settings(rawConfig);
    const diagnostics = { inboxRows: 0, messageRows: 0, unknownSender: 0, ambiguousSender: 0, ambiguousText: 0, invalidSelector: false, capped: false };
    // Invalid selectors always fail closed for this scan.
    for (const selector of Object.values(config.selectors)) query(document, selector, diagnostics);
    if (diagnostics.invalidSelector) return { inbox: [], thread: null, diagnostics };
    const output = { inbox: inbox(document, config, diagnostics), thread: thread(document, location, config, diagnostics), diagnostics };
    diagnostics.supported = output.inbox.length > 0 || !!output.thread?.supported;
    return output;
  }
  class Tracker {
    constructor({ warmupMs = 3000 } = {}) { this.warmupMs = warmupMs; this.reset(); }
    reset() { this.started = false; this.inbox = new Map(); this.threadId = null; this.keys = new Set(); this.lastTail = null; this.lastHead = null; this.lastTailNode = null; this.ordinal = 0; this.settleUntil = null; this.lastShape = null; }
    observe(snapshot, allowed, now = Date.now()) {
      const events = [], permitted = new Set(allowed);
      const shape = C.hash(JSON.stringify([snapshot.inbox.map(r => [r.thread, r.signature]), snapshot.thread?.id, snapshot.thread?.rows.map(r => r.key)]));
      if (this.settleUntil === null) this.settleUntil = now + this.warmupMs;
      if (now < this.settleUntil && shape !== this.lastShape) this.settleUntil = now + this.warmupMs;
      const warming = now < this.settleUntil;
      this.lastShape = shape;
      const oldInbox = this.inbox;
      this.inbox = new Map(snapshot.inbox.map(r => [r.thread, { signature: r.signature, unread: r.unread }]));
      for (const row of snapshot.inbox) {
        const old = oldInbox.get(row.thread);
        // First appearance is baseline, including initial unread messages or lazy-loaded rows.
        if ((snapshot.thread?.supported && snapshot.thread.id === row.thread) || warming || !this.started || !old || !row.unread || row.outgoing || !row.sender || !row.text || !permitted.has(row.sender)) continue;
        if (old.signature === row.signature) continue; // unread badge toggle/repaint is not a new message
        events.push(this.event(row, "inbox-preview", `preview:${row.signature}`, now));
      }
      const view = snapshot.thread;
      if (view) {
        const changedThread = this.threadId !== view.id;
        const oldKeys = this.keys;
        const oldTail = this.lastTail, oldHead = this.lastHead, oldTailNode = this.lastTailNode;
        this.threadId = view.id;
        // Content and sender/direction can hydrate in separate DOM mutations. An incomplete
        // incoming row must not move the tail before it is safe to deliver; outgoing rows
        // still anchor the transcript so the user's own replies never become notifications.
        const rows = view.rows.filter(r => r.outgoing || (r.incoming && r.sender && r.text));
        this.keys = new Set(rows.map(r => r.key));
        this.lastTail = rows[rows.length - 1]?.key || null;
        this.lastTailNode = rows[rows.length - 1]?.node || null;
        // Occurrence-numbered keys only shift when rows are added/removed above (history load,
        // virtualization). The same top DOM node means nothing moved above, so a repeat is genuinely new.
        this.lastHead = rows[0]?.node || null;
        const headStable = !!oldHead && this.lastHead === oldHead;
        // Instagram keeps only ~20 rows and drops the oldest as new ones arrive, which renumbers repeated
        // content. When the previous tail's own DOM node is still here, everything after it was appended:
        // new, whatever its text — no occurrence numbers involved.
        const tailAt = oldTailNode ? rows.findIndex(r => r.node === oldTailNode) : -1;
        if (!warming && !changedThread && this.started && view.atBottom && tailAt >= 0) {
          for (const row of rows.slice(tailAt + 1)) {
            if (!row.incoming || row.outgoing || !row.sender || !row.text || !permitted.has(row.sender)) continue;
            const timestamp = Date.parse(row.timestamp);
            if (Number.isFinite(timestamp) && (timestamp < now - 120000 || timestamp > now + 60000)) continue;
            events.push(this.event(row, "thread-message", row.key, now + events.length));
          }
        } else if (!warming && !changedThread && this.started && oldTail && view.atBottom) {
          // The tail node was replaced (re-render/navigation): fall back to content keys, conservatively.
          const boundary = rows.findIndex(r => r.key === oldTail);
          // If the old tail vanished (virtualization/navigation), rebaseline; never replay history.
          if (boundary >= 0) {
            for (const row of rows.slice(boundary + 1)) {
              if (oldKeys.has(row.key) || !row.incoming || row.outgoing || (row.ambiguousIdentity && !headStable) || !row.sender || !row.text || !permitted.has(row.sender)) continue;
              const timestamp = Date.parse(row.timestamp);
              if (Number.isFinite(timestamp) && (timestamp < now - 120000 || timestamp > now + 60000)) continue;
              // +index ms: rows found in one scan keep DOM order; the app sorts by observedAt, ties by hash.
              events.push(this.event(row, "thread-message", row.key, now + events.length));
            }
          }
        }
      } else { this.threadId = null; this.keys = new Set(); this.lastTail = null; this.lastHead = null; this.lastTailNode = null; }
      this.started = true;
      // The same thread is often visible in sidebar and main message list; prefer full row.
      const threadIds = new Set(events.filter(e => e.kind === "thread-message").map(e => e.threadUrl));
      return events.filter(e => e.kind !== "inbox-preview" || !threadIds.has(e.threadUrl));
    }
    event(row, kind, identity, now) {
      // Content keys (no server ID) repeat whenever the same text is sent again later; the observation time
      // makes each real arrival its own event, so worker/host deduplication never swallows a new repeat.
      const unique = row.serverId || kind !== "thread-message" ? identity : `${identity}@${now}`;
      return { version: 1, type: "dm", sender: row.sender, text: row.text, threadUrl: row.threadUrl,
        observedAt: new Date(now).toISOString(), kind,
        eventId: `ig:${C.hash([row.thread, row.sender, kind, unique].join("\u001f"))}` };
    }
  }
  const api = { scan, Tracker, profileUsers, resolveSender };
  root.PetDetector = api;
  if (typeof module !== "undefined") module.exports = api;
})(globalThis);
