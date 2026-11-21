import { BrowserControl, BrowserObservation } from '../pages/Browser';
import { NativeRuntime } from './NativeRuntime';
import { BrowserRelay, BrowserRelayReady, BrowserRelayRequest } from './BrowserRelay';

// The host supplies the actual visible session source. This equality check is
// binding to a host assertion, NOT independent authentication of the session.
export interface BrowserBridgeApproval {
  operation: string;
  sessionId: string;
  pageTitle: string;
  pageUrl: string;
  targetUrl: string;
  direction: string;
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
}

interface SnapshotData {
  title: string;
  url: string;
  items: SnapshotItem[];
}

interface ApprovedRequest {
  generation: number;
  sessionId: string;
  operation: string;
  targetUrl: string;
  direction: string;
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
    if (request.operation === 'scroll' && direction !== 'up' && direction !== 'down') { return false; }
    const details: BrowserBridgeApproval = { operation: request.operation, sessionId: request.sessionId,
      pageTitle: page.title, pageUrl: page.url, targetUrl: target, direction: direction };
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
      operation: request.operation, targetUrl: target, direction: direction, pageTitle: page.title, pageUrl: page.url };
    return true;
  }

  private take(operation: string, target: string, direction: string = ''): ApprovedRequest {
    const approval = this.approved;
    this.approved = undefined;
    if (!approval || approval.operation !== operation || approval.targetUrl !== target || approval.direction !== direction ||
      !this.samePage(approval.generation, approval.sessionId, approval.pageTitle, approval.pageUrl)) {
      throw new Error('Browser binding changed');
    }
    return approval;
  }

  private async open(target: string): Promise<string> {
    const approval = this.take('open', target);
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
    const approval = this.take('scroll', '', direction);
    this.control.scroll(approval.generation, direction);
    return 'Scroll call submitted; actual movement and page stability are not confirmed.';
  }

  private async observe(): Promise<string> {
    const approval = this.take('observe', '');
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
        (item.label === undefined || (typeof item.label === 'string' && item.label.length <= 300))) {
        const safe: SnapshotItem = { type: 'element', tag: item.tag };
        if (item.label !== undefined) { safe.label = item.label; }
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
