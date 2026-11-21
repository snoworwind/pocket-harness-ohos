// Fixed, read-only observation primitive for a future ArkWeb integration.
// The page is untrusted: returned strings are data, never instructions. This is
// best-effort visibility, not a privacy/security boundary against hostile JS.
// Only the supplied document is inspected: no frames, shadow roots, CSS-generated
// text, canvas, or accessibility tree. Clipping, occlusion, off-screen content,
// CSS tricks and hostile overrides can defeat visibility checks; do not treat
// this as a guarantee that hidden or sensitive information cannot be returned.
// URL/title/labels/text may themselves contain sensitive or misleading data.
// MAX_JSON bounds UTF-16 JSON length (therefore UTF-8 to at most 3x that).
// No interaction or script execution.
const MAX_ITEMS = 80;
const MAX_STRING = 300;
const MAX_NODES = 4000;
const MAX_DEPTH = 100;
const MAX_JSON = 24000;
const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'IFRAME', 'FRAME', 'OBJECT', 'EMBED', 'INPUT', 'TEXTAREA', 'SELECT', 'OPTION']);
const INTERACTIVE = new Set(['A', 'BUTTON', 'INPUT', 'TEXTAREA', 'SELECT']);

export function observePage(doc, view) {
  const result = { title: '', url: '', items: [] };
  const clean = (s) => typeof s === 'string' ? s.replace(/\s+/g, ' ').trim().slice(0, MAX_STRING) : '';
  // Each DOM read may throw or be overridden by page code. Fail closed.
  try { result.title = clean(doc.title); } catch { /* unavailable */ }
  try { result.url = clean(doc.location.href); } catch { /* unavailable */ }
  const add = (item) => {
    if (result.items.length >= MAX_ITEMS) return false;
    result.items.push(item);
    try {
      if (JSON.stringify(result).length <= MAX_JSON) return true;
    } catch { /* fail closed */ }
    result.items.pop();
    return false;
  };
  try {
    const root = doc.body;
    if (!root || !view || typeof view.getComputedStyle !== 'function') return result;
    const stack = [{ node: root, depth: 0, textVisible: false }];
    let visited = 0;
    while (stack.length && visited++ < MAX_NODES && result.items.length < MAX_ITEMS) {
      const { node, depth, textVisible } = stack.pop();
      if (!node || depth > MAX_DEPTH) continue;
      try {
        if (node.nodeType === 3) {
          const text = clean(node.nodeValue);
          if (textVisible && text && !add({ type: 'text', text })) break;
          continue;
        }
        if (node.nodeType !== 1) continue;
        const tag = typeof node.tagName === 'string' ? node.tagName.toUpperCase() : '';
        if (!tag || node.hidden || node.getAttribute('aria-hidden') === 'true') continue;
        // Editable regions can contain user-entered text: omit their subtrees.
        const editable = node.getAttribute('contenteditable');
        const role = node.getAttribute('role');
        if (node.isContentEditable || (typeof editable === 'string' &&
            /^(?:|true|plaintext-only)$/i.test(editable.trim())) ||
            (typeof role === 'string' && /(?:^|\s)(?:textbox|searchbox)(?:\s|$)/i.test(role))) continue;
        const style = view.getComputedStyle(node);
        if (!style || style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse' || Number(style.opacity) === 0) continue;
        // A zero-area box can still contain visible descendants (e.g. display:contents).
        // Require a box for the element itself, but still traverse its children.
        const rects = node.getClientRects();
        const hasBox = !!rects && rects.length > 0 && Array.prototype.some.call(rects, r => r.width > 0 && r.height > 0);
        if (INTERACTIVE.has(tag) && hasBox) {
          const item = { type: 'element', tag: tag.toLowerCase() };
          // Explicit labels only: never read value, placeholder, href, or form state.
          const label = clean(node.getAttribute('aria-label'));
          if (label) item.label = label;
          if (!add(item)) break;
        }
        if (SKIP.has(tag)) continue;
        const children = node.childNodes;
        // Bounded even if an adversarial collection reports an enormous length.
        const length = Math.min(Number(children.length) || 0, MAX_NODES);
        // display:contents contributes no box but its direct text may still be
        // rendered in the nearest boxed ancestor. Other boxless nodes remain hidden.
        const childTextVisible = hasBox || (style.display === 'contents' && textVisible);
        for (let i = length - 1; i >= 0; i--) stack.push({ node: children[i], depth: depth + 1, textVisible: childTextVisible });
      } catch { /* inaccessible or poisoned node: omit its entire subtree */ }
    }
  } catch { /* unavailable document */ }
  return result;
}

// Generate only this fixed program; never interpolate webpage or agent input.
// The host must obtain user consent and validate lifecycle before running it.
export function buildObserveScript() {
  const constants = `const MAX_ITEMS=${MAX_ITEMS},MAX_STRING=${MAX_STRING},MAX_NODES=${MAX_NODES},MAX_DEPTH=${MAX_DEPTH},MAX_JSON=${MAX_JSON};`;
  const tags = `const SKIP=new Set(${JSON.stringify([...SKIP])}),INTERACTIVE=new Set(${JSON.stringify([...INTERACTIVE])});`;
  return `(function(){${constants}${tags}const observePage=${observePage.toString()};return JSON.stringify(observePage(document,window));})()`;
}
