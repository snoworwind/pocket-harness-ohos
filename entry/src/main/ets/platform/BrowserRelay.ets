import { NativeProcess } from './NativeRuntime';
import { url } from '@kit.ArkTS';
import { BROWSER_ALLOWED_KEYS } from '../pages/BrowserObserveScript';

/*
 * Private relay adapter only: it neither starts a browser nor enables tools.
 * The caller constructs NativeProcess using the existing IEC node launcher,
 * intended cwd and unmodified runtime environment (envReplace is true). Pass
 * stdout and exit directly to this factory; do not log stdout or stderr.
 * Deliver ready information through an authenticated private channel, never a
 * URL, argv, environment, page or log. Same-UID code is not isolated.
 * The caller must obtain informed user approval for EACH request and bind the
 * callbacks to the approved browser instance and document; sessionId is an
 * untrusted claim, not authentication. Recheck that binding
 * before side effects. Callback completion means all side effects are finished.
 * Closing/timeout cannot cancel an already-running callback: its outcome is
 * UNKNOWN. Do not retry or start a replacement until the caller has independently
 * ensured all prior work has stopped. This object is permanently fused on close.
 */
export interface BrowserRelayReady {
  host: string;
  port: number;
  credential: string;
}

export interface BrowserRelayRequest {
  id: string;
  sessionId: string;
  operation: string;
  url?: string;
  direction?: string;
  ref?: string;
  text?: string;
  key?: string;
  action?: string;
  offset?: number;
  limit?: number;
}

export interface BrowserRelayCallbacks {
  deliverReady: (ready: BrowserRelayReady) => Promise<void>;
  // Called for every request. `automatic` is true only when the calling
  // Session's live permission preset allowed skipping the native dialog; the
  // implementation must still perform its page/session binding checks.
  authorize: (request: BrowserRelayRequest, automatic: boolean) => Promise<boolean>;
  open: (url: string) => Promise<string>;
  observe: () => Promise<string>;
  scroll: (direction: string) => Promise<string>;
  click: (ref: string) => Promise<string>;
  input: (ref: string, text: string, mode: string) => Promise<string>;
  press: (key: string) => Promise<string>;
  select: (ref: string, text: string) => Promise<string>;
  hover: (ref: string) => Promise<string>;
  text: (offset: number, limit: number) => Promise<string>;
  navigate: (action: string) => Promise<string>;
  onClosed?: () => void;
}

export type BrowserRelayFactory = (output: (text: string) => void,
  exit: (code: number, error: string) => void) => NativeProcess;

interface RelayFrame {
  type: string;
  version?: number;
  host?: string;
  port?: number;
  credential?: string;
  id?: string;
  sessionId?: string;
  operation?: string;
  url?: string;
  direction?: string;
  ref?: string;
  text?: string;
  key?: string;
  action?: string;
  // Present on the relay's reply to a policy-check frame.
  automatic?: boolean;
}

interface ResultFrame {
  type: string;
  id: string;
  ok: boolean;
  value?: string;
  error?: string;
}

// JSON.parse accepts duplicate names; reject them before interpreting a frame.
function uniqueTopLevelKeys(line: string): boolean {
  const keys: Set<string> = new Set<string>();
  let depth = 0;
  for (let i = 0; i < line.length; i++) {
    const ch = line.charAt(i);
    if (ch === '"') {
      const start = i;
      i++;
      while (i < line.length) {
        if (line.charAt(i) === '\\') { i += 2; continue; }
        if (line.charAt(i) === '"') { break; }
        i++;
      }
      if (i >= line.length) { return false; }
      let next = i + 1;
      while (next < line.length && /\s/.test(line.charAt(next))) { next++; }
      if (depth === 1 && line.charAt(next) === ':') {
        let key: string;
        try { key = JSON.parse(line.slice(start, i + 1)) as string; } catch (_error) { return false; }
        if (keys.has(key)) { return false; }
        keys.add(key);
      }
    } else if (ch === '{' || ch === '[') { depth++; }
    else if (ch === '}' || ch === ']') { depth--; }
  }
  return true;
}

function exactKeys(frame: RelayFrame, expected: string[]): boolean {
  const keys = Object.keys(frame);
  return keys.length === expected.length && expected.every((key: string) => keys.indexOf(key) >= 0);
}

// Count UTF-8 bytes, rejecting unpaired surrogate code units.
function utf8Size(text: string): number {
  let count = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c < 0x80) { count++; }
    else if (c < 0x800) { count += 2; }
    else if (c >= 0xd800 && c <= 0xdbff) {
      if (++i >= text.length) { return -1; }
      const low = text.charCodeAt(i);
      if (low < 0xdc00 || low > 0xdfff) { return -1; }
      count += 4;
    } else if (c >= 0xdc00 && c <= 0xdfff) { return -1; }
    else { count += 3; }
  }
  return count;
}

function asciiJson(value: ResultFrame): string {
  return JSON.stringify(value).replace(/[\u007f-\uffff]/g, (ch: string): string => {
    return '\\u' + ch.charCodeAt(0).toString(16).padStart(4, '0');
  }) + '\n';
}

export class BrowserRelay {
  private process?: NativeProcess;
  private callbacks: BrowserRelayCallbacks;
  private pending: string = '';
  private ready: boolean = false;
  private delivered: boolean = false;
  private busy: boolean = false;
  private stopped: boolean = false;
  private timer: number = -1;
  private ids: Set<string> = new Set<string>();
  // Pending approval-policy question. There is at most one per request because
  // the protocol forbids overlapping checks.
  private policyId: string = '';
  private policySettle?: (automatic: boolean) => void;

  constructor(factory: BrowserRelayFactory, callbacks: BrowserRelayCallbacks) {
    this.callbacks = callbacks;
    this.arm(5000);
    try {
      const process = factory((text: string) => this.onOutput(text),
        (_code: number, _error: string) => this.close());
      this.process = process;
      if (this.stopped) { process.close(); }
    } catch (_error) { this.close(); }
  }

  private arm(ms: number): void {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.close(), ms);
  }

  close(): void {
    if (this.stopped) { return; }
    this.stopped = true;
    clearTimeout(this.timer);
    this.pending = '';
    // A pending policy question must settle: fail closed to manual approval.
    const settle = this.policySettle;
    this.policySettle = undefined;
    this.policyId = '';
    if (settle) { settle(false); }
    try { this.callbacks.onClosed?.(); } catch (_error) { /* notification must not prevent closure */ }
    this.process?.close();
  }

  // Ask the DSH client whether the calling Session's live permission allows
  // skipping the native confirmation. Timeouts and closure settle to false so
  // the request falls back to a human decision instead of being approved.
  private requestPolicy(id: string): Promise<boolean> {
    if (this.stopped || !this.process || this.policySettle !== undefined) {
      return Promise.reject(new Error('Approval check unavailable'));
    }
    return new Promise<boolean>((resolve: (automatic: boolean) => void, reject: (error: Error) => void) => {
      const process = this.process;
      if (!process) { reject(new Error('Approval check unavailable')); return; }
      this.policyId = id;
      this.policySettle = resolve;
      try {
        process.write('{"type":"policy-check","id":"' + id + '"}\n').catch(() => {
          if (this.policySettle === resolve) {
            this.policySettle = undefined;
            this.policyId = '';
            this.close();
          }
          reject(new Error('Approval check failed'));
        });
      } catch (_error) {
        this.policySettle = undefined;
        this.policyId = '';
        reject(new Error('Approval check failed'));
      }
    });
  }

  private onOutput(text: string): void {
    if (this.stopped) { return; }
    this.pending += text;
    while (!this.stopped) {
      const end = this.pending.indexOf('\n');
      if (end < 0) {
        if (utf8Size(this.pending) < 0 || utf8Size(this.pending) > 8192) { this.close(); }
        return;
      }
      const line = this.pending.slice(0, end);
      this.pending = this.pending.slice(end + 1);
      const size = utf8Size(line);
      if (size <= 0 || size > 8192 || line.indexOf('\r') >= 0 || !uniqueTopLevelKeys(line)) { this.close(); return; }
      let frame: RelayFrame;
      try { frame = JSON.parse(line) as RelayFrame; } catch (_error) { this.close(); return; }
      if (!frame || typeof frame !== 'object' || Array.isArray(frame)) { this.close(); return; }
      this.onFrame(frame);
    }
  }

  private onFrame(frame: RelayFrame): void {
    if (!this.ready) {
      if (!exactKeys(frame, ['type', 'version', 'host', 'port', 'credential']) ||
        frame.type !== 'ready' || frame.version !== 1 || frame.host !== '127.0.0.1' ||
        typeof frame.port !== 'number' || !Number.isInteger(frame.port) || frame.port < 1 || frame.port > 65535 ||
        typeof frame.credential !== 'string' || !/^[a-f0-9]{64}$/.test(frame.credential)) { this.close(); return; }
      this.ready = true;
      const info: BrowserRelayReady = { host: frame.host, port: frame.port, credential: frame.credential };
      this.arm(5000);
      this.callbacks.deliverReady(info).then(() => {
        if (!this.stopped) { this.delivered = true; clearTimeout(this.timer); }
      }).catch(() => this.close());
      return;
    }
    // Reply to a pending approval-policy question for the active request.
    if (frame.type === 'policy') {
      if (!exactKeys(frame, ['type', 'id', 'automatic']) || typeof frame.id !== 'string' ||
        typeof frame.automatic !== 'boolean' || this.policySettle === undefined || frame.id !== this.policyId) {
        this.close(); return;
      }
      const settle = this.policySettle;
      this.policySettle = undefined;
      this.policyId = '';
      settle(frame.automatic);
      return;
    }
    if (!this.delivered || this.busy || frame.type !== 'request' || typeof frame.id !== 'string' ||
      !/^[A-Za-z0-9_-]{1,64}$/.test(frame.id) || typeof frame.sessionId !== 'string' ||
      !/^[A-Za-z0-9_-]{1,128}$/.test(frame.sessionId) || this.ids.has(frame.id) || this.ids.size >= 10000) {
      this.close(); return;
    }
    if (frame.operation === 'observe') {
      if (!exactKeys(frame, ['type', 'id', 'sessionId', 'operation'])) { this.close(); return; }
    } else if (frame.operation === 'scroll') {
      if (!exactKeys(frame, ['type', 'id', 'sessionId', 'operation', 'direction']) ||
        (frame.direction !== 'up' && frame.direction !== 'down')) { this.close(); return; }
    } else if (frame.operation === 'click' || frame.operation === 'hover') {
      if (!exactKeys(frame, ['type', 'id', 'sessionId', 'operation', 'ref']) ||
        typeof frame.ref !== 'string' || !/^e\d{1,3}$/.test(frame.ref) ||
        Number(frame.ref.slice(1)) >= 80) { this.close(); return; }
    } else if (frame.operation === 'fill' || frame.operation === 'type' || frame.operation === 'select') {
      if (!exactKeys(frame, ['type', 'id', 'sessionId', 'operation', 'ref', 'text']) ||
        typeof frame.ref !== 'string' || !/^e\d{1,3}$/.test(frame.ref) || Number(frame.ref.slice(1)) >= 80 ||
        typeof frame.text !== 'string' || !/^[A-Za-z0-9+/]*={0,2}$/.test(frame.text) ||
        frame.text.length > 1536) { this.close(); return; }
    } else if (frame.operation === 'press') {
      if (!exactKeys(frame, ['type', 'id', 'sessionId', 'operation', 'key']) ||
        typeof frame.key !== 'string' || BROWSER_ALLOWED_KEYS.indexOf(frame.key) < 0) { this.close(); return; }
    } else if (frame.operation === 'text') {
      if (!exactKeys(frame, ['type', 'id', 'sessionId', 'operation', 'offset', 'limit']) ||
        typeof frame.offset !== 'number' || !Number.isSafeInteger(frame.offset) ||
        frame.offset < 0 || frame.offset > 200000 ||
        typeof frame.limit !== 'number' || !Number.isSafeInteger(frame.limit) ||
        frame.limit < 1 || frame.limit > 8000) { this.close(); return; }
    } else if (frame.operation === 'navigate') {
      if (!exactKeys(frame, ['type', 'id', 'sessionId', 'operation', 'action']) ||
        (frame.action !== 'back' && frame.action !== 'forward' && frame.action !== 'refresh')) { this.close(); return; }
    } else if (frame.operation === 'open') {
      if (!exactKeys(frame, ['type', 'id', 'sessionId', 'operation', 'url']) || typeof frame.url !== 'string' ||
        utf8Size(frame.url) < 0 || utf8Size(frame.url) > 4096 || /[\u0000-\u0020\u007f]/.test(frame.url) ||
        !/^https?:\/\//i.test(frame.url)) { this.close(); return; }
      try {
        const parsed = new url.URL(frame.url);
        const protocol = parsed.protocol.toLowerCase().replace(/:$/, '');
        if ((protocol !== 'http' && protocol !== 'https') || !parsed.hostname || parsed.username || parsed.password) {
          this.close(); return;
        }
      } catch (_error) { this.close(); return; }
    } else { this.close(); return; }
    this.ids.add(frame.id);
    this.busy = true;
    this.arm(29000);
    const request: BrowserRelayRequest = { id: frame.id, sessionId: frame.sessionId,
      operation: frame.operation, url: frame.url, direction: frame.direction, ref: frame.ref,
      text: frame.text, key: frame.key, action: frame.action, offset: frame.offset, limit: frame.limit };
    this.execute(request).catch(() => this.close());
  }

  private async execute(request: BrowserRelayRequest): Promise<void> {
    let value: string;
    let ok: boolean = false;
    try {
      // A false answer, an error or a timeout all fall back to the native
      // dialog. When the first answer allows automatic mode, ask again right
      // before binding: a preset switched mid-flight must not inherit it.
      let automatic = await this.requestPolicy(request.id);
      if (this.stopped) { return; }
      if (automatic) {
        automatic = await this.requestPolicy(request.id);
        if (this.stopped) { return; }
      }
      const approved = await this.callbacks.authorize(request, automatic);
      if (this.stopped) { return; }
      if (!approved) { value = 'Denied'; }
      else {
        value = request.operation === 'open' ? await this.callbacks.open(request.url as string) :
          request.operation === 'scroll' ? await this.callbacks.scroll(request.direction as string) :
          request.operation === 'click' ? await this.callbacks.click(request.ref as string) :
          (request.operation === 'fill' || request.operation === 'type') ?
            await this.callbacks.input(request.ref as string, request.text as string, request.operation) :
          request.operation === 'press' ? await this.callbacks.press(request.key as string) :
          request.operation === 'select' ? await this.callbacks.select(request.ref as string, request.text as string) :
          request.operation === 'hover' ? await this.callbacks.hover(request.ref as string) :
          request.operation === 'text' ? await this.callbacks.text(request.offset as number, request.limit as number) :
          request.operation === 'navigate' ? await this.callbacks.navigate(request.action as string) :
          await this.callbacks.observe();
        ok = true;
      }
    } catch (_error) {
      // Callback failures may have partial side effects; never claim a definitive result.
      this.close(); return;
    }
    if (this.stopped) { return; }
    if (typeof value !== 'string' || utf8Size(value) < 0 || utf8Size(value) > 65536) { this.close(); return; }
    const result: ResultFrame = ok ? { type: 'result', id: request.id, ok: true, value: value } :
      { type: 'result', id: request.id, ok: false, error: value };
    const encoded = asciiJson(result);
    if (encoded.length - 1 > 131072 || !this.process) { this.close(); return; }
    try { await this.process.write(encoded); } catch (_error) { this.close(); return; }
    if (!this.stopped) { this.busy = false; clearTimeout(this.timer); }
  }
}
