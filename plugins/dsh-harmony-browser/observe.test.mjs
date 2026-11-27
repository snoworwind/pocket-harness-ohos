import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { observePage, buildObserveScript, buildClickScriptTemplate, buildHoverScript, buildHoverScriptTemplate, buildInputScriptTemplate, buildPressScriptTemplate, buildSelectScriptTemplate, textPage, buildTextScript, buildTextScriptTemplate } from './observe.js';
import vm from 'node:vm';

const text = value => ({ nodeType: 3, nodeValue: value });
function element(tag, children = [], attrs = {}, style = {}) {
  return { nodeType: 1, tagName: tag.toUpperCase(), childNodes: children, hidden: false,
    getAttribute(name) { return attrs[name] ?? null; },
    getClientRects() { return [{ width: 10, height: 10 }]; }, style };
}
const view = { getComputedStyle(n) { return { display: 'block', visibility: 'visible', opacity: '1', ...n.style }; } };
const documentFor = body => ({ title: ' Test page ', location: { href: 'https://example.test/' }, body });

test('returns visible text and controls without form values or hidden subtrees', () => {
  const input = element('input', [], { 'aria-label': 'Search' });
  Object.defineProperty(input, 'value', { get() { throw Error('value read'); } });
  const body = element('body', [text(' hello '), element('button', [text('Go')]), input,
    element('textarea', [text('secret textarea')]), element('select', [element('option', [text('secret option')])]),
    element('div', [text('hidden')], {}, { display: 'none' }),
    element('div', [text('aria hidden')], { 'aria-hidden': 'true' }),
    element('iframe', [text('frame secret')]), element('script', [text('script secret')])]);
  assert.deepEqual(observePage(documentFor(body), view), { title: 'Test page', url: 'https://example.test/', items: [
    { type: 'text', text: 'hello' }, { type: 'element', tag: 'button' }, { type: 'text', text: 'Go' },
    { type: 'element', tag: 'input', label: 'Search' }, { type: 'element', tag: 'textarea' }, { type: 'element', tag: 'select' },
  ] });
});

test('editable and ARIA textbox subtrees never reveal user-entered text', () => {
  const inherited = element('div', [text('inherited secret')]); inherited.isContentEditable = true;
  const body = element('body', [text('visible'), element('div', [text('secret')], { contenteditable: '' }),
    element('div', [text('secret')], { contenteditable: 'plaintext-only' }),
    element('div', [text('secret')], { role: 'textbox' }),
    element('div', [text('secret')], { role: 'searchbox' }), inherited]);
  assert.deepEqual(observePage(documentFor(body), view).items, [{ type: 'text', text: 'visible' }]);
});

test('bounds number, length and total output', () => {
  const result = observePage({ title: 't'.repeat(1000), location: { href: 'u'.repeat(1000) }, body: element('body', Array.from({ length: 1000 }, () => text('x'.repeat(1000)))) }, view);
  assert.ok(result.title.length <= 300 && result.url.length <= 300);
  assert.ok(result.items.length <= 80);
  assert.ok(result.items.every(item => item.text.length <= 300));
  assert.ok(JSON.stringify(result).length <= 24000);
});

test('poisoned nodes, inaccessible document and hidden or boxless nodes fail closed', () => {
  const poisoned = element('div', [text('no')]);
  poisoned.getAttribute = () => { throw Error('poison'); };
  const boxless = element('span', [text('not rendered')]);
  boxless.getClientRects = () => [];
  const body = element('body', [poisoned, boxless, element('div', [text('transparent')], {}, { opacity: '0' }), text('safe')]);
  assert.deepEqual(observePage(documentFor(body), view).items, [{ type: 'text', text: 'safe' }]);
  assert.deepEqual(observePage(null, view), { title: '', url: '', items: [] });
});

test('display:contents preserves visible text without exposing hidden ancestors', () => {
  const contents = element('span', [text('rendered')], {}, { display: 'contents' });
  contents.getClientRects = () => [];
  const hidden = element('div', [contents], {}, { display: 'none' });
  const body = element('body', [contents, hidden]);
  assert.deepEqual(observePage(documentFor(body), view).items, [{ type: 'text', text: 'rendered' }]);
});

test('fixed script runs without module imports or interpolated page data', () => {
  const doc = documentFor(element('body', [text('safe')]));
  const result = vm.runInNewContext(buildObserveScript(), { document: doc, window: view });
  assert.deepEqual(JSON.parse(result), observePage(doc, view));
});

test('node traversal is bounded under cycles', () => {
  const body = element('body'); body.childNodes.push(body);
  assert.deepEqual(observePage(documentFor(body), view).items, []);
});

test('a truncated snapshot is flagged, a complete one is not', () => {
  const many = element('body', Array.from({ length: 120 }, () => element('button', [text('go')])));
  const cut = observePage(documentFor(many), view);
  assert.equal(cut.truncated, true);
  assert.ok(cut.items.length <= 80);
  const small = observePage(documentFor(element('body', [element('button', [text('go')])])), view);
  assert.equal('truncated' in small, false);
});

test('hover script substitutes only a bounded index and never page data', () => {
  const script = buildHoverScript('e7');
  assert.match(script, /refs\[7\]/);
  assert.match(script, /"hovered"/);
  assert.match(script, /mouseenter/);
  assert.match(script, /elementFromPoint/);
  assert.equal(buildHoverScriptTemplate().includes('__PH_INDEX__'), true);
  assert.throws(() => buildHoverScript('e80'), /Invalid element reference/);
  assert.throws(() => buildHoverScript('x1'), /Invalid element reference/);
});

test('text extraction returns prose, honors the window and never leaks form values', () => {
  const body = element('body', [
    text(' hello world '),
    element('p', [text('second paragraph')]),
    element('input', [text('secret input')]),
    element('textarea', [text('secret area')]),
    element('script', [text('var x=1')]),
    element('div', [text('hidden text')], {}, { display: 'none' })
  ]);
  const full = textPage(documentFor(body), view, 0, 1000);
  assert.match(full.text, /hello world/);
  assert.match(full.text, /second paragraph/);
  assert.equal(full.text.includes('secret'), false);
  assert.equal(full.text.includes('var x'), false);
  assert.equal(full.text.includes('hidden text'), false);
  const win = textPage(documentFor(body), view, 0, 5);
  assert.ok(win.text.length <= 5);
  assert.equal(win.truncated, true);
  assert.equal(textPage(documentFor(body), view, -1, 10).text, '');
});

test('text script carries only integer bounds and a fixed program', () => {
  const script = buildTextScript(40, 200);
  assert.match(script, /textPage\(document,window,40,200\)/);
  assert.equal(buildTextScriptTemplate().includes('__PH_OFFSET__'), true);
  assert.throws(() => buildTextScript(-1, 10), /Invalid text offset/);
  assert.throws(() => buildTextScript(0, 9000), /Invalid text limit/);
});

test('ArkTS script templates stay byte-identical to the generated ones', async () => {
  // BrowserObserveScript.ets is a generated snapshot. Without this check it can
  // silently drift from observe.js, which is exactly how a missing constant once
  // shipped a browser_text that threw on every device.
  const source = fs.readFileSync(new URL('../../entry/src/main/ets/pages/BrowserObserveScript.ets', import.meta.url), 'utf8');
  const pairs = [
    ['BROWSER_OBSERVE_SCRIPT', buildObserveScript()],
    ['BROWSER_CLICK_SCRIPT_TEMPLATE', buildClickScriptTemplate()],
    ['BROWSER_INPUT_SCRIPT_TEMPLATE', buildInputScriptTemplate()],
    ['BROWSER_PRESS_SCRIPT_TEMPLATE', buildPressScriptTemplate()],
    ['BROWSER_SELECT_SCRIPT_TEMPLATE', buildSelectScriptTemplate()],
    ['BROWSER_HOVER_SCRIPT_TEMPLATE', buildHoverScriptTemplate()],
    ['BROWSER_TEXT_SCRIPT_TEMPLATE', buildTextScriptTemplate()]
  ];
  for (const [name, expected] of pairs) {
    const match = source.match(new RegExp('^export const ' + name + ': string = (.*);$', 'm'));
    assert.ok(match, 'missing ' + name + ' in BrowserObserveScript.ets');
    assert.equal(JSON.parse(match[1]), expected, name + ' has drifted from observe.js');
  }
});
