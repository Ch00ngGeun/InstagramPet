// Paste into the DevTools console of an open Instagram 1:1 DM thread (or inbox).
// Prints a structure-only skeleton: no text, usernames, IDs, classes, URLs or images.
// Review the output before sharing. See docs/DOM-DRIFT.md.
(() => {
  const IN = /^(?:message from|message sent by|sent by|보낸 사람|메시지를 보낸 사람)/i;
  const OUT = /^(?:you(?: sent|:)|(?:message )?sent by you|message from you|내가 보낸|회원님이 보낸|나:)/i;
  const KEEP = new Set(["role", "dir", "tabindex", "aria-hidden", "aria-live", "aria-expanded", "aria-describedby", "aria-labelledby"]);
  const doc = document, scope = doc.querySelector("main, [role='main']") || doc.body;
  const count = s => { try { return doc.querySelectorAll(s).length; } catch { return "err"; } };
  const kind = v => IN.test(v) ? "in" : OUT.test(v) ? "out" : `other${v.length}`;
  function href(v) {
    let p; try { p = new URL(v, location.origin).pathname; } catch { return "bad"; }
    if (/^\/direct\/t\//.test(p)) return "/direct/t/12345/";
    if (/^\/[A-Za-z0-9._]{1,30}\/?$/.test(p)) return "/fixture.user/";
    return "/other";
  }
  function attrs(el) {
    const out = [];
    for (const { name, value } of el.attributes) {
      if (KEEP.has(name)) out.push(/^aria-(labelledby|describedby)$/.test(name) ? `${name}="x"` : `${name}="${value.replace(/[^\w-]/g, "")}"`);
      else if (name === "aria-label" || name === "title") out.push(`${name}="${kind(value.trim())}"`);
      else if (name.startsWith("data-")) out.push(`${name}="v"`);
      else if (name === "href") out.push(`href="${href(value)}"`);
      else if (name === "alt") out.push(`alt="${/profile picture|프로필 사진/i.test(value) ? "profile" : "other"}"`);
      else if (name === "datetime") out.push(`datetime="dt"`);
    }
    return out.length ? " " + out.join(" ") : "";
  }
  function skel(el, depth) {
    if (depth > 60) return "…";
    let wraps = 0;
    // Collapse attribute-less single-child wrappers that Instagram nests deeply.
    while (el.children.length === 1 && el.childNodes.length === 1 && !attrs(el) && el.tagName === "DIV") { el = el.children[0]; wraps++; }
    const tag = el.tagName.toLowerCase();
    if (["svg", "script", "style", "template"].includes(tag)) return `<${tag}/>`;
    const inner = Array.from(el.childNodes).map(n => n.nodeType === 3 ? (n.textContent.trim() ? `T${n.textContent.trim().length}` : "")
      : n.nodeType === 1 ? skel(n, depth + 1) : "").filter(Boolean).join("");
    return `${wraps ? `[div×${wraps}]` : ""}<${tag}${attrs(el)}>${inner}</${tag}>`;
  }
  function side(el) {
    const r = el.getBoundingClientRect(), s = scope.getBoundingClientRect();
    if (!r.width) return "?";
    return r.left - s.left > s.right - r.right + 40 ? "R" : r.right - s.left < s.width / 2 + 40 ? "L" : "C";
  }
  // The message list is usually the tallest scrollable element in the main area.
  const scroller = [...scope.querySelectorAll("*")].filter(e => e.scrollHeight > e.clientHeight + 50)
    .sort((a, b) => b.scrollHeight - a.scrollHeight)[0] || scope;
  let list = scroller;
  while (list.children.length === 1) list = list.children[0];
  const rows = [...list.children].slice(-8);
  const report = [
    `# Instagram Pet DOM probe ${new Date().toISOString().slice(0, 10)} page=${/\/direct\/t\//.test(location.pathname) ? "thread" : "other"}`,
    `counts: ${["[role='row']", "[role='gridcell']", "[role='grid']", "[role='log']", "[role='list']", "[role='listitem']", "[data-message-id]", "[data-item-id]", "a[href*='/direct/t/']", "time[datetime]", "[dir='auto']", "img[alt]"].map(s => `${s}=${count(s)}`).join(" ")}`,
    `labels: ${[...scope.querySelectorAll("[aria-label]")].map(e => kind(e.getAttribute("aria-label").trim())).filter(k => k === "in" || k === "out").join(",") || "none-in/out"}`,
    `last ${rows.length} children of message list (side: L=left R=right C=center):`,
    ...rows.map((r, i) => `--- row ${i + 1} side=${side(r)}\n${skel(r, 0)}`)
  ].join("\n").slice(0, 40000);
  try { copy(report); console.log("Copied to clipboard. Review before sharing."); } catch { /* copy() exists only in DevTools */ }
  console.log(report);
  return report;
})();
