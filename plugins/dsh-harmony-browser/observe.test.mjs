import test from 'node:test';
import assert from 'node:assert/strict';
import { observePage, buildObserveScript } from './observe.js';
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
