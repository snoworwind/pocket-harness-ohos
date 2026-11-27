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
          // Visible text of the control itself (button captions, link text). Inputs
          // and selects are skipped: their descendants hold values/options, and
          // reading those would leak form state.
          if (tag === 'A' || tag === 'BUTTON') {
            const caption = clean(node.textContent).slice(0, 80);
            if (caption) item.caption = caption;
          }
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
    // Borrowed from agent-browser: fail instead of reporting success when the
    // target is outside the viewport or covered by another element.
    'const rect=el.getBoundingClientRect();const x=rect.left+rect.width/2,y=rect.top+rect.height/2;' +
    'if(x<0||y<0||x>globalThis.innerWidth||y>globalThis.innerHeight)return "offscreen";' +
    'let top=null;try{top=document.elementFromPoint(x,y);}catch(e){top=null;}' +
    'if(top&&top!==el&&!el.contains(top)&&!top.contains(el))return "covered";' +
    'el.click();return "clicked";}catch(e){return "error";}})()';
}

// ---------------------------------------------------------------------------
// Text entry, key presses and select options.
//
// Semantics follow agent-browser / playwright-mcp: fill clears before entering,
// type appends; both refuse elements that cannot take text instead of reporting
// success. After acting, the value is read back: a page that rewrites or
// truncates it is reported by STATUS ONLY (never by echoing field content).
//
// Text is carried as base64. The program source is fixed apart from a bounded
// integer index, a base64 literal ([A-Za-z0-9+/=]) and an enum word; no page or
// agent text is ever concatenated as code.
// ---------------------------------------------------------------------------

export const MAX_TEXT = 512;
export const INDEX_PLACEHOLDER = '__PH_INDEX__';
export const TEXT_PLACEHOLDER = '__PH_B64__';
export const MODE_PLACEHOLDER = '__PH_MODE__';
export const KEY_PLACEHOLDER = '__PH_KEY__';

// Printable text keys plus the editing/navigation keys an agent needs.
export const ALLOWED_KEYS = Object.freeze([
  'Enter', 'Tab', 'Escape', 'Backspace', 'Delete', 'Home', 'End',
  'PageUp', 'PageDown', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Space'
]);

// Inputs that can never take free text (mirrors agent-browser's not_editable).
const NON_TEXT_INPUT_TYPES = ['checkbox', 'radio', 'file', 'hidden', 'image', 'button',
  'submit', 'reset', 'range', 'color', 'date', 'time', 'datetime-local', 'month', 'week'];

export function validateRef(ref) {
  if (typeof ref !== 'string' || !/^e\d{1,3}$/.test(ref)) throw new Error('Invalid element reference');
  const index = Number(ref.slice(1));
  if (!Number.isSafeInteger(index) || index >= MAX_ITEMS) throw new Error('Invalid element reference');
  return index;
}

export function validateText(text) {
  if (typeof text !== 'string') throw new Error('Invalid text');
  if (text.length > MAX_TEXT) throw new Error('Text too long');
  // Reject C0/C1 controls; newline and tab stay allowed for multi-line fields.
  if (/[ ---]/.test(text)) throw new Error('Text contains control characters');
  return text;
}

export function validateKey(key) {
  if (typeof key !== 'string' || !ALLOWED_KEYS.includes(key)) throw new Error('Unsupported key');
  return key;
}

export function encodeText(text) {
  validateText(text);
  return Buffer.from(text, 'utf8').toString('base64');
}

function decodeSnippet(placeholder) {
  // base64 -> bytes -> UTF-8. atob yields Latin-1, so decode explicitly.
  return 'const bin=atob("' + placeholder + '");const bytes=new Uint8Array(bin.length);' +
    'for(let i=0;i<bin.length;i++)bytes[i]=bin.charCodeAt(i);' +
    'const text=new TextDecoder().decode(bytes);';
}

export function buildInputScript(ref, base64, mode) {
  const index = validateRef(ref);
  if (typeof base64 !== 'string' || !/^[A-Za-z0-9+/]*={0,2}$/.test(base64) || base64.length > MAX_TEXT * 3) {
    throw new Error('Invalid encoded text');
  }
  if (mode !== 'fill' && mode !== 'type') throw new Error('Invalid input mode');
  return inputScriptFor(index, base64, mode);
}

export function buildInputScriptTemplate() {
  return inputScriptFor(INDEX_PLACEHOLDER, TEXT_PLACEHOLDER, MODE_PLACEHOLDER);
}

function inputScriptFor(index, base64, mode) {
  return '(function(){try{' +
    'const refs=globalThis.' + REFS_KEY + ';const el=refs&&refs[' + index + '];' +
    'if(!el||el.isConnected!==true)return "stale";' +
    'const tag=(el.tagName||"").toUpperCase();' +
    'if(el.disabled===true)return "disabled";' +
    'let editable=false;' +
    'if(tag==="TEXTAREA")editable=true;' +
    'else if(tag==="INPUT"){const t=(el.type||"text").toLowerCase();' +
    'if(' + JSON.stringify(NON_TEXT_INPUT_TYPES) + '.indexOf(t)>=0)return "not_editable";editable=true;}' +
    'if(!editable)return "not_editable";' +
    'if(el.readOnly===true)return "readonly";' +
    decodeSnippet(base64) +
    'el.focus();' +
    'const mode="' + mode + '";' +
    'const current=typeof el.value==="string"?el.value:"";' +
    'const expected=mode==="fill"?text:current+text;' +
    'if(expected.length>4096)return "too_long";' +
    'const proto=tag==="TEXTAREA"?globalThis.HTMLTextAreaElement.prototype:globalThis.HTMLInputElement.prototype;' +
    'let setter=null;try{const d=Object.getOwnPropertyDescriptor(proto,"value");setter=d&&d.set?d.set:null;}catch(e){setter=null;}' +
    // React/Vue controlled inputs track the native setter, not el.value = x.
    'if(mode==="fill"){if(setter)setter.call(el,"");else el.value="";' +
    'el.dispatchEvent(new Event("input",{bubbles:true,composed:true}));}' +
    'if(setter)setter.call(el,expected);else el.value=expected;' +
    'el.dispatchEvent(new Event("input",{bubbles:true,composed:true}));' +
    'el.dispatchEvent(new Event("change",{bubbles:true}));' +
    // Read back without echoing field content: only status, never the value.
    'const after=typeof el.value==="string"?el.value:"";' +
    'if(after===expected)return mode==="fill"?"filled":"typed";' +
    'if(expected.indexOf(after)===0&&after.length<expected.length)return "truncated";' +
    'return "rewritten";' +
    '}catch(e){return "error";}})()';
}

export function buildPressScript(key) {
  validateKey(key);
  return pressScriptFor(key);
}

export function buildPressScriptTemplate() {
  return pressScriptFor(KEY_PLACEHOLDER);
}

function pressScriptFor(key) {
  return '(function(){try{' +
    'const key="' + key + '";' +
    'const el=document.activeElement;' +
    'if(!el)return "no_focus";' +
    // Synthetic key events do not trigger native default actions; Enter on a
    // form control additionally requests submission, which is why every press
    // still needs its own native approval.
    'const opts={key:key,code:key,bubbles:true,cancelable:true,composed:true};' +
    'el.dispatchEvent(new KeyboardEvent("keydown",opts));' +
    'el.dispatchEvent(new KeyboardEvent("keypress",opts));' +
    'el.dispatchEvent(new KeyboardEvent("keyup",opts));' +
    'if(key==="Enter"){let form=null;try{form=el.form||(el.closest?el.closest("form"):null);}catch(e){form=null;}' +
    'if(form&&typeof form.requestSubmit==="function"){form.requestSubmit();return "submitted";}}' +
    'return "pressed";' +
    '}catch(e){return "error";}})()';
}

export function buildSelectScript(ref, base64) {
  const index = validateRef(ref);
  if (typeof base64 !== 'string' || !/^[A-Za-z0-9+/]*={0,2}$/.test(base64) || base64.length > MAX_TEXT * 3) {
    throw new Error('Invalid encoded value');
  }
  return selectScriptFor(index, base64);
}

export function buildSelectScriptTemplate() {
  return selectScriptFor(INDEX_PLACEHOLDER, TEXT_PLACEHOLDER);
}

function selectScriptFor(index, base64) {
  return '(function(){try{' +
    'const refs=globalThis.' + REFS_KEY + ';const el=refs&&refs[' + index + '];' +
    'if(!el||el.isConnected!==true)return "stale";' +
    'if((el.tagName||"").toUpperCase()!=="SELECT")return "not_select";' +
    'if(el.disabled===true)return "disabled";' +
    decodeSnippet(base64) +
    'const options=el.options;if(!options)return "error";' +
    'let byValue=-1,byLabel=-1,valueMatches=0,labelMatches=0;' +
    'for(let i=0;i<options.length;i++){' +
    'if(options[i].value===text){if(byValue<0)byValue=i;valueMatches++;}' +
    'if(options[i].label===text||options[i].text===text){if(byLabel<0)byLabel=i;labelMatches++;}}' +
    'if(byValue>=0&&byLabel>=0&&byValue!==byLabel)return "ambiguous";' +
    'if(byValue<0&&labelMatches>1)return "ambiguous";' +
    'const idx=byValue>=0?byValue:byLabel;' +
    'if(idx<0)return "option_not_found";' +
    'if(options[idx].disabled===true)return "disabled";' +
    'el.focus();el.selectedIndex=idx;' +
    'el.dispatchEvent(new Event("input",{bubbles:true,composed:true}));' +
    'el.dispatchEvent(new Event("change",{bubbles:true}));' +
    'return el.selectedIndex===idx?"selected":"rewritten";' +
    '}catch(e){return "error";}})()';
}
