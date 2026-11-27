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
// Property name used to hand element references from the snapshot to the click
// program. Deliberately obscure but not secret: the page can observe it.
export const REFS_KEY = '__phBrowserRefs';
const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'IFRAME', 'FRAME', 'OBJECT', 'EMBED', 'INPUT', 'TEXTAREA', 'SELECT', 'OPTION']);
const INTERACTIVE = new Set(['A', 'BUTTON', 'INPUT', 'TEXTAREA', 'SELECT']);

// `register` is an optional host callback that receives each interactive element
// and returns a short opaque reference (or undefined to omit it). References are
// only meaningful to the snapshot that produced them and must be revalidated by
// the host before any interaction; they are not authorization tokens.
export function observePage(doc, view, register) {
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
          if (typeof register === 'function') {
            // A page can throw from the callback or return junk; drop the ref instead.
            try {
              const ref = register(node);
              if (typeof ref === 'string' && /^e\d{1,3}$/.test(ref)) item.ref = ref;
            } catch { /* omit ref */ }
          }
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
  // References live only for the lifetime of the latest snapshot. Assigning the
  // array is best-effort: a hostile page may have frozen or replaced it, in which
  // case clicks report 'stale' rather than acting on an unexpected element.
  const refs = `const refs=[];try{globalThis.${REFS_KEY}=refs;}catch{}const register=(node)=>{const ref='e'+refs.length;refs.push(node);return ref;};`;
  return `(function(){${constants}${tags}${refs}const observePage=${observePage.toString()};return JSON.stringify(observePage(document,window,register));})()`;
}

// The click program is fixed: the only interpolated value is a bounded integer
// index derived from a strictly validated reference. Nothing from the page or
// the agent is concatenated into the script source.
export function buildClickScript(ref) {
  if (typeof ref !== 'string' || !/^e\d{1,3}$/.test(ref)) throw new Error('Invalid element reference');
  const index = Number(ref.slice(1));
  if (!Number.isSafeInteger(index) || index >= MAX_ITEMS) throw new Error('Invalid element reference');
  return clickScriptForIndex(index);
}

// Same fixed program, with the index left as a literal placeholder. Hosts that
// cannot import this module embed the template and substitute a validated
// integer only; never substitute page or agent text.
export const CLICK_INDEX_PLACEHOLDER = '__PH_INDEX__';

export function buildClickScriptTemplate() {
  return clickScriptForIndex(CLICK_INDEX_PLACEHOLDER);
}

function clickScriptForIndex(index) {
  return `(function(){try{const refs=globalThis.${REFS_KEY};const el=refs&&refs[${index}];` +
    'if(!el||el.isConnected!==true||typeof el.click!=="function")return "stale";' +
    'if(el.disabled===true)return "disabled";' +
    'const rects=el.getClientRects();if(!rects||rects.length===0)return "hidden";' +
    'let style=null;try{style=globalThis.getComputedStyle?globalThis.getComputedStyle(el):null;}catch(e){style=null;}' +
    'if(style&&(style.display==="none"||style.visibility==="hidden"||style.visibility==="collapse"))return "hidden";' +
    'el.click();return "clicked";}catch(e){return "error";}})()';
}
