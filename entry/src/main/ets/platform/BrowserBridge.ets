import { BrowserControl, BrowserObservation } from '../pages/Browser';
import { NativeRuntime } from './NativeRuntime';
import { BrowserRelay, BrowserRelayReady, BrowserRelayRequest } from './BrowserRelay';
import { BROWSER_ACTION_STATUSES, BROWSER_ALLOWED_KEYS } from '../pages/BrowserObserveScript';

// The host supplies the actual visible session source. This equality check is
// binding to a host assertion, NOT independent authentication of the session.
export interface BrowserBridgeApproval {
  operation: string;
  sessionId: string;
  pageTitle: string;
  pageUrl: string;
  targetUrl: string;
  direction: string;
  ref: string;
  key: string;
  action: string;
  // Only the length is surfaced for text entry: the approval UI must not log or
  // leak field content, which may be a password or other secret.
  textLength: number;
}

export interface BrowserBridgeHost {
  visibleSessionId: () => string | null;
  authorize: (details: BrowserBridgeApproval) => Promise<boolean>;
  // Optional informational notification when the calling Session's permission
  // preset allowed skipping the dialog. It must never grant anything.
  automaticApproved?: (details: BrowserBridgeApproval) => void;
  // Trusted native-only delivery; never put credentials into a page or log.
  deliverReady: (ready: BrowserRelayReady) => Promise<void>;
  // Close any pending native approval UI; must not expose relay credentials.
  onClosed?: () => void;
}

interface SnapshotItem {
  type: string;
  text?: string;
  tag?: string;
  label?: string;
  ref?: string;
  caption?: string;
}

interface SnapshotData {
  title: string;
  url: string;
  items: SnapshotItem[];
}

interface ApprovedRequest {
  generation: number;
  sessionId: string;
  signature: string;
  pageTitle: string;
  pageUrl: string;
}

// No implicit startup. One instance is single-use, including after failure or
// stop: the relay cannot cancel a callback already in progress. Integrators
// must validate SDK behavior on device and supply an accurate session source
// and genuinely private credential injection before enabling this bridge.
export class BrowserBridge {
  private runtime: NativeRuntime;
  private control: BrowserControl;
  private host: BrowserBridgeHost;
  private relay?: BrowserRelay;
  private started: boolean = false;
  private stopped: boolean = false;
  private navigationSubmitted: boolean = false;
  private pendingSession: string = '';
  private approved?: ApprovedRequest;

  constructor(runtime: NativeRuntime, control: BrowserControl, host: BrowserBridgeHost) {
    this.runtime = runtime;
    this.control = control;
    this.host = host;
  }

  start(): void {
    if (this.started || this.stopped) { throw new Error('Browser bridge is single-use'); }
    this.started = true;
    this.relay = new BrowserRelay(
      (output: (text: string) => void, exit: (code: number, error: string) => void) =>
        this.runtime.startBrowserRelay(output, (code: number) => exit(code, '')),
      {
        deliverReady: async (ready: BrowserRelayReady): Promise<void> => {
          if (this.stopped) { throw new Error('Bridge stopped'); }
          await this.host.deliverReady(ready);
          if (this.stopped) { throw new Error('Bridge stopped'); }
        },
        authorize: (request: BrowserRelayRequest, automatic: boolean): Promise<boolean> => this.authorize(request, automatic),
        open: (target: string): Promise<string> => this.open(target),
        observe: (): Promise<string> => this.observe(),
        scroll: (direction: string): Promise<string> => this.scroll(direction),
        click: (ref: string): Promise<string> => this.click(ref),
        input: (ref: string, text: string, mode: string): Promise<string> => this.input(ref, text, mode),
        press: (key: string): Promise<string> => this.press(key),
        select: (ref: string, text: string): Promise<string> => this.select(ref, text),
        navigate: (action: string): Promise<string> => this.navigate(action),
        onClosed: (): void => this.closed()
      });
    if (this.stopped) { this.relay.close(); }
  }

  stop(): void {
    if (this.stopped) { return; }
    this.closed();
    this.relay?.close();
  }

  // Only the native confirmation button calls this method, never a relay or page.
  // ArkWeb has no navigation ID: a same-URL stale event cannot be ruled out.
  // This binds to the page visible at the click, not to network stability; SPA
  // changes can still occur. Each subsequent operation needs its own approval.
  confirmCurrentPage(): boolean {
    if (this.stopped || !this.started || !this.navigationSubmitted || !this.pendingSession ||
      this.host.visibleSessionId() !== this.pendingSession) { return false; }
    const page = this.control.rebindPage();
    if (page === null || this.host.visibleSessionId() !== this.pendingSession ||
      this.control.currentGeneration() !== page.generation) { return false; }
    this.control.consumeRebind();
    this.pendingSession = '';
    this.approved = undefined;
    this.navigationSubmitted = false;
    return true;
  }

  // This notification never calls relay.close(), avoiding recursive closure.
  private closed(): void {
    if (this.stopped) { return; }
    this.stopped = true;
    this.approved = undefined;
    this.pendingSession = '';
    this.control.consumeRebind();
    try { this.host.onClosed?.(); } catch (_error) { /* closure must continue */ }
  }

  private matches(generation: number, sessionId: string): boolean {
    return !this.stopped && !this.navigationSubmitted &&
      this.control.currentGeneration() === generation && this.host.visibleSessionId() === sessionId;
  }

  private samePage(generation: number, sessionId: string, title: string, pageUrl: string): boolean {
    if (!this.matches(generation, sessionId)) { return false; }
    const page = this.control.observe(generation);
    return page !== null && page.title === title && page.url === pageUrl && this.matches(generation, sessionId);
  }

  private async authorize(request: BrowserRelayRequest, automatic: boolean = false): Promise<boolean> {
    this.approved = undefined;
    if (this.stopped || this.navigationSubmitted || !request.sessionId ||
      this.host.visibleSessionId() !== request.sessionId) { return false; }
    const generation = this.control.currentGeneration();
    if (generation === null) { return false; }
    const page: BrowserObservation | null = this.control.observe(generation);
    if (page === null || !this.matches(generation, request.sessionId) ||
      (page.url === 'about:blank' && request.operation !== 'open')) { return false; }
    const target = request.url || '';
    const direction = request.direction || '';
    const ref = request.ref || '';
    const text = request.text || '';
    const key = request.key || '';
    const action = request.action || '';
    if (request.operation === 'scroll' && direction !== 'up' && direction !== 'down') { return false; }
    if (request.operation === 'click' && !isValidRef(ref)) { return false; }
    if ((request.operation === 'fill' || request.operation === 'type' || request.operation === 'select') &&
      (!isValidRef(ref) || !isValidEncodedText(text))) { return false; }
    if (request.operation === 'press' && BROWSER_ALLOWED_KEYS.indexOf(key) < 0) { return false; }
    if (request.operation === 'navigate' && action !== 'back' && action !== 'forward' && action !== 'refresh') { return false; }
    const details: BrowserBridgeApproval = { operation: request.operation, sessionId: request.sessionId,
      pageTitle: page.title, pageUrl: page.url, targetUrl: target, direction: direction, ref: ref,
      key: key, action: action, textLength: textLengthOf(text) };
    if (automatic) {
      // The calling Session's live preset already covers this call; skip only
      // the human dialog. Every page/session binding check below still applies.
      try { this.host.automaticApproved?.(details); } catch (_error) { /* notification only */ }
    } else {
      const accepted = await this.host.authorize(details);
      if (!accepted) { return false; }
    }
    if (!this.samePage(generation, request.sessionId, page.title, page.url)) { return false; }
    this.approved = { generation: generation, sessionId: request.sessionId,
      signature: signatureOf(request.operation, target, direction, ref, text, key, action),
      pageTitle: page.title, pageUrl: page.url };
    return true;
  }

  private take(signature: string): ApprovedRequest {
    const approval = this.approved;
    this.approved = undefined;
    if (!approval || approval.signature !== signature ||
      !this.samePage(approval.generation, approval.sessionId, approval.pageTitle, approval.pageUrl)) {
      throw new Error('Browser binding changed');
    }
    return approval;
  }

  private async open(target: string): Promise<string> {
    const approval = this.take(signatureOf('open', target));
    // A page-end event is only a prerequisite for native confirmation, not a
    // completion or stability guarantee. Arm before loadUrl to catch sync events.
    this.navigationSubmitted = true;
    this.pendingSession = approval.sessionId;
    if (!this.control.armRebind(approval.generation) || !this.control.open(approval.generation, target)) {
      throw new Error('Navigation submission failed');
    }
    return 'Navigation submitted; final page load is not confirmed.';
  }

  private async scroll(direction: string): Promise<string> {
    const approval = this.take(signatureOf('scroll', '', direction));
    this.control.scroll(approval.generation, direction);
    return 'Scroll call submitted; actual movement and page stability are not confirmed.';
  }

  private async click(ref: string): Promise<string> {
    const approval = this.take(signatureOf('click', '', '', ref));
    // Checks bracket the asynchronous ArkWeb execution. A click may navigate or
    // mutate the page; the returned status only attests that it was dispatched.
    if (!this.samePage(approval.generation, approval.sessionId, approval.pageTitle, approval.pageUrl)) {
      throw new Error('Browser binding changed');
    }
    const raw = await this.control.click(approval.generation, ref);
    const status = decodeActionStatus(raw);
    if (status !== 'clicked') { throw new Error('Browser click not dispatched: ' + status); }
    return 'Click dispatched; page reaction, navigation and stability are not confirmed.';
  }

  private async input(ref: string, text: string, mode: string): Promise<string> {
    if (mode !== 'fill' && mode !== 'type') { throw new Error('Invalid input mode'); }
    const approval = this.take(signatureOf(mode, '', '', ref, text));
    if (!this.samePage(approval.generation, approval.sessionId, approval.pageTitle, approval.pageUrl)) {
      throw new Error('Browser binding changed');
    }
    const raw = await this.control.input(approval.generation, ref, text, mode);
    const status = decodeActionStatus(raw);
    // A filled/typed result only means the field held the requested value at
    // read-back; the page may still rewrite it later or navigate away.
    if (status === 'filled') { return 'Field filled; value matched at read-back. Later page rewrites are not excluded.'; }
    if (status === 'typed') { return 'Text appended; value matched at read-back. Later page rewrites are not excluded.'; }
    if (status === 'truncated') { return 'Text was truncated by the field (for example maxlength); value length is not reported.'; }
    if (status === 'rewritten') { return 'The page rewrote the value after entry; field content is not reported.'; }
    throw new Error('Browser input not applied: ' + status);
  }

  private async press(key: string): Promise<string> {
    const approval = this.take(signatureOf('press', '', '', '', '', key));
    if (!this.samePage(approval.generation, approval.sessionId, approval.pageTitle, approval.pageUrl)) {
      throw new Error('Browser binding changed');
    }
    const raw = await this.control.press(approval.generation, key);
    const status = decodeActionStatus(raw);
    if (status === 'pressed') { return 'Key events dispatched; native default actions are not guaranteed.'; }
    if (status === 'submitted') { return 'Key events dispatched and form submission was requested; resulting navigation is not confirmed.'; }
    throw new Error('Browser key press not applied: ' + status);
  }

  private async select(ref: string, text: string): Promise<string> {
    const approval = this.take(signatureOf('select', '', '', ref, text));
    if (!this.samePage(approval.generation, approval.sessionId, approval.pageTitle, approval.pageUrl)) {
      throw new Error('Browser binding changed');
    }
    const raw = await this.control.select(approval.generation, ref, text);
    const status = decodeActionStatus(raw);
    if (status === 'selected') { return 'Option selected and change events dispatched; page reaction is not confirmed.'; }
    throw new Error('Browser select not applied: ' + status);
  }

  private async navigate(action: string): Promise<string> {
    const approval = this.take(signatureOf('navigate', '', '', '', '', '', action));
    this.control.navigate(approval.generation, action);
    return 'Navigation submitted; the new document is not loaded or confirmed. Take a fresh snapshot before acting.';
  }

  private async observe(): Promise<string> {
    const approval = this.take(signatureOf('observe'));
    // Checks bracket the asynchronous ArkWeb execution. URL/title checks cannot
    // detect all SPA changes, including changes that revert before completion.
    if (!this.samePage(approval.generation, approval.sessionId, approval.pageTitle, approval.pageUrl)) {
      throw new Error('Browser binding changed');
    }
    const raw = await this.control.snapshot(approval.generation);
    if (!this.samePage(approval.generation, approval.sessionId, approval.pageTitle, approval.pageUrl)) {
      throw new Error('Browser binding changed');
    }
    // ArkWeb may return the script's JSON string as a JSON-encoded string.
    // Treat all page results as hostile: limit before parsing and reconstruct a
    // narrowly typed response rather than forwarding arbitrary page properties.
    if (typeof raw !== 'string' || raw.length > 150000) { throw new Error('Invalid snapshot'); }
    let decoded: string = raw;
    if (raw.startsWith('"')) {
      decoded = JSON.parse(raw) as string;
    }
    if (typeof decoded !== 'string' || decoded.length > 24000) { throw new Error('Invalid snapshot'); }
    const data: SnapshotData = JSON.parse(decoded) as SnapshotData;
    if (!data || !Array.isArray(data.items) || data.items.length > 80) { throw new Error('Invalid snapshot'); }
    const items: SnapshotItem[] = [];
    for (const item of data.items) {
      if (!item || typeof item.type !== 'string') { throw new Error('Invalid snapshot'); }
      if (item.type === 'text' && typeof item.text === 'string' && item.text.length <= 300) {
        items.push({ type: 'text', text: item.text });
      } else if (item.type === 'element' && typeof item.tag === 'string' &&
        ['a', 'button', 'input', 'textarea', 'select'].includes(item.tag) &&
        (item.label === undefined || (typeof item.label === 'string' && item.label.length <= 300)) &&
        (item.caption === undefined || (typeof item.caption === 'string' && item.caption.length <= 80)) &&
        (item.ref === undefined || (typeof item.ref === 'string' && isValidRef(item.ref)))) {
        const safe: SnapshotItem = { type: 'element', tag: item.tag };
        if (item.label !== undefined) { safe.label = item.label; }
        if (item.ref !== undefined) { safe.ref = item.ref; }
        if (item.caption !== undefined) { safe.caption = item.caption; }
        items.push(safe);
      } else { throw new Error('Invalid snapshot'); }
    }
    const title = approval.pageTitle.slice(0, 300);
    const pageUrl = approval.pageUrl.slice(0, 300);
    let output = JSON.stringify({ untrusted: true, title: title, url: pageUrl, items: items });
    // Bound output without failing an otherwise valid, text-heavy page. Remove
    // complete items only; never emit malformed JSON or conceal truncation.
    if (output.length > 16000) {
      while (items.length > 0) {
        items.pop();
        output = JSON.stringify({ untrusted: true, title: title, url: pageUrl, items: items, truncated: true });
        if (output.length <= 16000) { break; }
      }
      if (output.length > 16000) { throw new Error('Snapshot too large'); }
    }
    return output;
  }
}

// Element references are bounded, opaque indices produced by the snapshot.
// They are not authorization: the native approval is still per-request.
export function isValidRef(ref: string): boolean {
  if (typeof ref !== 'string' || !/^e\d{1,3}$/.test(ref)) { return false; }
  const index = Number(ref.slice(1));
  return Number.isSafeInteger(index) && index >= 0 && index < 80;
}

// Text never travels as source code: it is base64 and only decoded inside the
// fixed page program. This also bounds the relay frame size.
export function isValidEncodedText(text: string): boolean {
  return typeof text === 'string' && /^[A-Za-z0-9+/]*={0,2}$/.test(text) && text.length <= 1536;
}

export function textLengthOf(text: string): number {
  if (!isValidEncodedText(text)) { return 0; }
  const padding = text.endsWith('==') ? 2 : (text.endsWith('=') ? 1 : 0);
  return Math.max(0, Math.floor(text.length * 3 / 4) - padding);
}

// The approval signature binds the exact arguments the user approved to the
// arguments later executed. Any mismatch invalidates the approval.
export function signatureOf(operation: string, url: string = '', direction: string = '', ref: string = '',
  text: string = '', key: string = '', action: string = ''): string {
  return [operation, url, direction, ref, text, key, action].join('\u0001');
}

// ArkWeb may hand back the script result as a JSON-encoded string. Only the
// fixed set of status words is accepted; anything else fails closed.
export function decodeActionStatus(raw: string): string {
  if (typeof raw !== 'string' || raw.length > 64) { return 'invalid'; }
  let value: string = raw;
  if (raw.startsWith('"')) {
    try { value = JSON.parse(raw) as string; } catch (_error) { return 'invalid'; }
  }
  return BROWSER_ACTION_STATUSES.indexOf(value) >= 0 ? value : 'invalid';
}
