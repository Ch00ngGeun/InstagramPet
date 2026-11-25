/* Instagram DM 화면(받은편지함 행과 열린 스레드)을 스냅샷으로 읽고,
   Tracker는 연속된 스냅샷에서 새로 도착한 받은 메시지만 이벤트로 만든다. */
(function (root) {
  "use strict";
  const C = root.PetCommon || require("./common.js");
  const RESERVED = new Set(["direct", "explore", "accounts", "reels", "p", "stories", "about", "legal", "privacy", "developer", "notifications"]);
  const INCOMING = /^(?:message from|message sent by|sent by|보낸 사람|메시지를 보낸 사람)\s*[:：]?\s*(@?[a-z0-9._]{1,30})(?=\s|:|：|$)/i;
  const OUTGOING = /^(?:you(?: sent|:)|(?:message )?sent by you|message from you(?:\s|:|$)|내가 보낸|회원님이 보낸|나:)/i;
  // 실제 한국어 UI(2026-11-06 확인): 메시지마다 동작 버튼 라벨이 "<username>님의 메시지에 답장하기"이다.
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
      } catch { /* 잘못된 페이지 링크는 무시한다. */ }
    }
    return [...found].filter(Boolean);
  }
  function resolveSender(node, binding, diagnostics, senderOnly = false) {
    // 표시 이름과 본문 멘션은 계정 식별자가 아니다. 메시지 행에서는 프로필 사진
    // 이미지를 감싼 프로필 URL만 인정하고, 방향은 따로 판단한다.
    // 보통의 대안은 사용자가 확인한 1:1 바인딩이다.
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
    // 행 전체 텍스트보다 미리보기의 접근성 설명을 우선한다.
    const describedBy = row.getAttribute("aria-describedby");
    if (describedBy) {
      const parts = describedBy.split(/\s+/).map(id => row.ownerDocument.getElementById(id)).filter(Boolean);
      if (parts.length) return parts.map(text).join(" ");
    }
    // Instagram은 보낸 사람과 미리보기를 별도 dir=auto 조각으로 그리는 경우가 많다.
    // 일부러 보수적으로 잡은 대안이다: 따로 떨어진 텍스트 조각이 없는 행은 버린다.
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
        // 미리보기에 서버 시각이 없으면 같은 내용 반복을 정확히 가려낸다고 보장하지 않는다.
        signature: C.hash([sender, preview, timestamp, outgoing].join("\u001f")) });
      diagnostics.inboxRows++;
      if (!sender) diagnostics.unknownSender++;
    }
    return result;
  }
  const EMOJI_ONLY = /^[\p{Extended_Pictographic}\p{Emoji_Component}\u200d\ufe0f\s]+$/u;
  // 실제 한국어 UI(2026-11-06): 이모지만 있는 말풍선엔 dir=auto 조각이 없다. 공유된 릴스·게시물은
  // 썸네일과 작성자 링크가 든 버튼이고, 릴스엔 "클립" 라벨 svg가 붙으며, 스토리 공유는 /stories/로 링크된다.
  // DM 사진·동영상은 항목마다 버튼 하나이고 썸네일 alt에 종류가 적힌다("사진…"/"동영상…").
  const VIDEO_ALT = /동영상|video/i, PHOTO_ALT = /사진|photo|image|이미지/i, PROFILE_ALT = /프로필|profile/i;
  // 동영상 재생 아이콘은 instagram.com에서 오는 고정 .png다. 사진·썸네일은 CDN에서 오며 스크린샷처럼 .png일 수도 있다.
  function playIcon(src) {
    try { return /\.png(?:$|\?)/.test(src || "") && /(^|\.)instagram\.com$/.test(new URL(src, "https://www.instagram.com").hostname); }
    catch { return false; }
  }
  function mediaItem(node, diagnostics) {
    const imgs = query(node, "img", diagnostics).filter(i => !PROFILE_ALT.test(i.getAttribute("alt") || ""));
    const alts = imgs.map(i => i.getAttribute("alt") || "");
    // 막 도착한 실제 말풍선은 alt가 비어 있었다(2026-11-25 실제 화면 재확인): 동영상은 CDN 썸네일 위에 재생 아이콘이 있다.
    const icon = imgs.some(i => playIcon(i.getAttribute("src"))), thumbs = imgs.filter(i => !playIcon(i.getAttribute("src")));
    if (query(node, "video", diagnostics).length || alts.some(a => VIDEO_ALT.test(a)) || (icon && thumbs.length)) return "(동영상)";
    return alts.some(a => PHOTO_ALT.test(a)) || (!icon && thumbs.length === 1) ? "(이미지)" : null;
  }
  function media(body, diagnostics) {
    // 항목별 링크(스토리·릴스·게시물 ID)를, 없으면 썸네일을 키로 써서 서로 다른 공유가 합쳐지지 않게 한다.
    const src = query(body, "a[href*='/stories/'], a[href*='/reel/'], a[href*='/p/']", diagnostics)[0]?.getAttribute("href") ||
      query(body, "video[src], img[src]", diagnostics).map(n => n.getAttribute("src")).find(v => !playIcon(v)) || "";
    let key = ""; try { key = src && C.hash(new URL(src, "https://www.instagram.com").pathname); } catch { /* 쓸 수 없는 src */ }
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
    // 중첩 후보와 사이드바 링크는 제외한다: 가장 깊은 메시지 행이 단위다.
    const rowSet = new Set(rows);
    rows = rows.filter(n => visible(n) && !Array.from(n.querySelectorAll(ROWS)).some(x => rowSet.has(x)));
    const occurrences = new Map(), result = [];
    for (const row of rows) {
      if (query(row, "a[href*='/direct/t/']", diagnostics).length) continue;
      const actor = actionSender(row, diagnostics);
      // 사용자가 확인한 1:1 스레드에서 상대가 아닌 이름의 동작 라벨은 사용자 본인 메시지다.
      const outgoing = !!isOutgoing(row, config, diagnostics) || (!!binding && !!actor && actor !== binding);
      const accessibleSender = label(row).match(INCOMING)?.[1];
      const incoming = !outgoing && (!!accessibleSender || !!actor || (config.selectors.incomingMessage && matches(row, config.selectors.incomingMessage, diagnostics)));
      const sender = incoming ? (actor || resolveSender(row, binding, diagnostics, true)) : null;
      let message = "", mediaKey = "";
      if (config.selectors.messageText) message = text(query(row, config.selectors.messageText, diagnostics)[0]);
      else {
        // 말풍선 본문은 role=article 안에 있고, 이름과 시간 구분선은 그 바깥에 있다.
        const body = query(row, "[role='article']", diagnostics)[0] || row;
        const texts = query(body, "[dir='auto']", diagnostics).filter(n => !n.querySelector("[dir='auto']") && !n.closest("a, button, [role='button']")).map(text).filter(Boolean);
        // 텍스트 조각이 여럿(예: 메시지 + 반응)이면 모호하다. 사용자가 선택자를 보정할 수 있다.
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
    // 스크롤되지 않는 목록은 이미 끝에 있다. 가상화된 스크롤 영역은 맨 아래에 있어야 한다.
    // 실제 Instagram은 column-reverse 스크롤을 쓴다: 맨 아래가 scrollTop 0이고, 위로 올리면 음수다.
    const reversed = !!scroll && /reverse/.test(document.defaultView?.getComputedStyle(scroll).flexDirection || "");
    const atBottom = !scroll || scroll.scrollHeight <= scroll.clientHeight + 16 ||
      (reversed ? Math.abs(scroll.scrollTop) < 100 : scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < 100);
    for (const item of result) {
      // 고정 항목 ID나 기계 판독 시각이 없으면 똑같은 반복 행을 이전 기록 추가나
      // 가상화로 인한 밀림과 안전하게 구분할 수 없다. 이런 행은 억제한다.
      const fingerprint = item.key.match(/^fp:([^:]+):/ )?.[1];
      item.ambiguousIdentity = !item.serverId && !item.timestamp && (occurrences.get(fingerprint) || 0) > 1;
    }
    return { id: current.id, url: current.url, rows: result, atBottom, supported: result.length > 0 };
  }
  function scan(document, location, rawConfig) {
    const config = C.settings(rawConfig);
    const diagnostics = { inboxRows: 0, messageRows: 0, unknownSender: 0, ambiguousSender: 0, ambiguousText: 0, invalidSelector: false, capped: false };
    // 잘못된 선택자가 있으면 이번 검사는 항상 아무것도 내보내지 않는다.
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
        // 처음 보이는 행은 기준선이다. 처음부터 있던 안 읽은 메시지나 늦게 로드된 행도 마찬가지다.
        if ((snapshot.thread?.supported && snapshot.thread.id === row.thread) || warming || !this.started || !old || !row.unread || row.outgoing || !row.sender || !row.text || !permitted.has(row.sender)) continue;
        if (old.signature === row.signature) continue; // 안 읽음 배지 토글이나 다시 그리기는 새 메시지가 아니다
        events.push(this.event(row, "inbox-preview", `preview:${row.signature}`, now));
      }
      const view = snapshot.thread;
      if (view) {
        const changedThread = this.threadId !== view.id;
        const oldKeys = this.keys;
        const oldTail = this.lastTail, oldHead = this.lastHead, oldTailNode = this.lastTailNode;
        this.threadId = view.id;
        // 내용과 보낸 사람·방향은 서로 다른 DOM 변경으로 채워질 수 있다. 덜 채워진 받은 행은
        // 전달해도 안전해지기 전까지 끝 위치를 옮기면 안 된다. 보낸 행은 그래도 기준점이 되어
        // 사용자 본인 답장이 알림이 되는 일은 없다.
        const rows = view.rows.filter(r => r.outgoing || (r.incoming && r.sender && r.text));
        this.keys = new Set(rows.map(r => r.key));
        this.lastTail = rows[rows.length - 1]?.key || null;
        this.lastTailNode = rows[rows.length - 1]?.node || null;
        // 등장 순번 키는 위쪽에 행이 추가·삭제될 때(이전 기록 로드, 가상화)만 밀린다.
        // 맨 위 DOM 노드가 같다면 위쪽은 그대로이므로 반복 내용은 정말 새 메시지다.
        this.lastHead = rows[0]?.node || null;
        const headStable = !!oldHead && this.lastHead === oldHead;
        // Instagram은 약 20개 행만 유지하고 새 행이 오면 가장 오래된 행을 지워 반복 내용의 순번이 바뀐다.
        // 이전 끝 행의 DOM 노드가 아직 있으면 그 뒤의 행은 모두 새로 붙은 것이다:
        // 내용과 상관없이 새 메시지이며, 순번은 쓰지 않는다.
        const tailAt = oldTailNode ? rows.findIndex(r => r.node === oldTailNode) : -1;
        if (!warming && !changedThread && this.started && view.atBottom && tailAt >= 0) {
          for (const row of rows.slice(tailAt + 1)) {
            if (!row.incoming || row.outgoing || !row.sender || !row.text || !permitted.has(row.sender)) continue;
            const timestamp = Date.parse(row.timestamp);
            if (Number.isFinite(timestamp) && (timestamp < now - 120000 || timestamp > now + 60000)) continue;
            events.push(this.event(row, "thread-message", row.key, now + events.length));
          }
        } else if (!warming && !changedThread && this.started && oldTail && view.atBottom) {
          // 끝 노드가 교체됨(다시 그리기/이동): 보수적으로 내용 기반 키로 대신 판단한다.
          const boundary = rows.findIndex(r => r.key === oldTail);
          // 이전 끝 행이 사라졌다면(가상화/이동) 기준선을 새로 잡는다. 지난 기록은 절대 다시 보내지 않는다.
          if (boundary >= 0) {
            for (const row of rows.slice(boundary + 1)) {
              if (oldKeys.has(row.key) || !row.incoming || row.outgoing || (row.ambiguousIdentity && !headStable) || !row.sender || !row.text || !permitted.has(row.sender)) continue;
              const timestamp = Date.parse(row.timestamp);
              if (Number.isFinite(timestamp) && (timestamp < now - 120000 || timestamp > now + 60000)) continue;
              // +index ms: 한 번에 찾은 행들이 DOM 순서를 유지하게 한다. 앱은 observedAt으로, 같으면 해시로 정렬한다.
              events.push(this.event(row, "thread-message", row.key, now + events.length));
            }
          }
        }
      } else { this.threadId = null; this.keys = new Set(); this.lastTail = null; this.lastHead = null; this.lastTailNode = null; }
      this.started = true;
      // 같은 스레드가 사이드바와 본문 메시지 목록에 함께 보이는 경우가 많다. 본문 행을 우선한다.
      const threadIds = new Set(events.filter(e => e.kind === "thread-message").map(e => e.threadUrl));
      return events.filter(e => e.kind !== "inbox-preview" || !threadIds.has(e.threadUrl));
    }
    event(row, kind, identity, now) {
      // 내용 기반 키(서버 ID 없음)는 같은 글이 나중에 다시 오면 겹친다. 관찰 시각을 붙여 실제 도착마다
      // 별도 이벤트로 만들어, 워커·호스트 중복 제거가 새 반복 메시지를 삼키지 않게 한다.
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
