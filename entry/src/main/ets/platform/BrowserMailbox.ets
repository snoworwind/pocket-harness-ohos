import { url } from '@kit.ArkTS';

// Experimental, disabled v2 receiver. Nothing imports or starts this module.
// The caller must explicitly authorize each operation and call these methods
// manually. There is no timer, browser integration, or control endpoint here.
//
// No OHOS filesystem adapter is supplied: CoreFileKit's cross-process exclusive
// mkdir, directory fsync, rename and durable mkdir(done) semantics have NOT been
// verified. Supplying an adapter without establishing ALL contracts below is
// unsafe. In particular, ordinary mkdir followed by directory fsync is NOT a
// valid implementation of makeDone: the producer may delete the slot as soon as
// done appears. All paths and their ancestors must be private, trusted and free
// of symlinks; cooperating peers must never reuse a generation.

const MAX_BYTES: number = 64 * 1024;

export interface MailboxPayload {
  operation: string;
  url?: string;
}

interface RequestEnvelope {
  version: number;
  generation: string;
  deadline: number;
  payload: MailboxPayload;
}

interface ResponseEnvelope {
  version: number;
  generation: string;
  ok: boolean;
  value: Object;
}

// All methods MUST be asynchronous and do filesystem work off the UI thread.
// Errors other than a documented absent/existing result must reject. listActive
// must be bounded and return null unless there is exactly one valid generation;
// it must not ignore errors or scan an unbounded directory. readRequest returns
// null only for ENOENT and otherwise strictly decodes UTF-8, rejecting malformed
// input and reads over maxBytes (including a bounded extra-byte check).
// tryClaim performs a cross-process atomic exclusive mkdir and persists its
// parent directory before returning true; existing or missing slot returns false.
// revoked checks BOTH active/revoke and generation/revoke; absence must be
// distinguished from permission/I/O failures. publishResponse must exclusively
// create a unique temporary file, write all UTF-8 bytes, fsync and close it,
// atomically rename it to response, and fsync the generation directory. It must
// reject if the encoded JSON exceeds maxBytes. makeDone must atomically create a
// durable exclusive done marker in one operation, with no subsequent slot access,
// even if it fails or reports an ambiguous result. None of these operations may
// clean up, follow symlinks or act on a replacement generation.
export interface BrowserMailboxBackend {
  listActive(root: string): Promise<string | null>;
  readRequest(root: string, generation: string, maxBytes: number): Promise<string | null>;
  tryClaim(root: string, generation: string): Promise<boolean>;
  revoked(root: string, generation: string): Promise<boolean>;
  publishResponse(root: string, generation: string, json: string, maxBytes: number): Promise<void>;
  makeDone(root: string, generation: string): Promise<void>;
}

function exactKeys(value: Object, expected: string[]): boolean {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) { return false; }
  const keys = Object.keys(value);
  return keys.length === expected.length && expected.every((key: string) => keys.indexOf(key) >= 0);
}

function validGeneration(generation: string): boolean {
  return /^[0-9a-f]{48}$/.test(generation);
}

function parseRequest(text: string, generation: string): RequestEnvelope {
  const request = JSON.parse(text) as RequestEnvelope;
  if (!exactKeys(request, ['version', 'generation', 'deadline', 'payload']) ||
    request.version !== 2 || request.generation !== generation ||
    !Number.isSafeInteger(request.deadline) || request.deadline <= 0) {
    throw new Error('invalid mailbox envelope or deadline');
  }
  const payload = request.payload;
  if (!payload || !((exactKeys(payload, ['operation']) && payload.operation === 'observe') ||
    (exactKeys(payload, ['operation', 'url']) && payload.operation === 'open' &&
      typeof payload.url === 'string' && payload.url.length > 0))) {
    throw new Error('invalid mailbox payload');
  }
  if (payload.operation === 'open') {
    try {
      const target = payload.url as string;
      if (target.length > 4096 || /[\u0000-\u0020\u007f]/.test(target)) { throw new Error('invalid URL'); }
      const parsed = new url.URL(target);
      const protocol = parsed.protocol.toLowerCase().replace(/:$/, '');
      if ((protocol !== 'http' && protocol !== 'https') || !parsed.hostname || parsed.username || parsed.password) {
        throw new Error('invalid URL');
      }
    } catch (error) { throw new Error('invalid browser URL'); }
  }
  return request;
}

// Created only after an exclusive claim. The object is single-use even when an
// operation throws; it must not be persisted, cloned, replayed or shared.
class BrowserMailboxClaim {
  private used: boolean = false;
  private backend: BrowserMailboxBackend;
  private root: string;
  private request: RequestEnvelope;

  constructor(backend: BrowserMailboxBackend, root: string, request: RequestEnvelope) {
    this.backend = backend;
    this.root = root;
    this.request = request;
  }

  // This is the only invocation point. The caller must explicitly authorize the
  // displayed operation before calling. Revocation and deadline are best effort:
  // they can race the callback and cannot stop an action already started.
  async completeAuthorized(execute: (payload: MailboxPayload) => Promise<Object>): Promise<boolean> {
    if (this.used) { throw new Error('claim already consumed'); }
    this.used = true;
    const generation = this.request.generation;
    if (await this.backend.revoked(this.root, generation)) { return false; }
    if (Date.now() >= this.request.deadline) { return false; }
    let response: ResponseEnvelope;
    try {
      const value = await execute(this.request.payload);
      response = { version: 2, generation: generation, ok: true, value: value };
    } catch (error) {
      response = { version: 2, generation: generation, ok: false, value: String(error) };
    }
    const json = JSON.stringify(response);
    if (typeof json !== 'string') { throw new Error('response serialization failed'); }
    await this.backend.publishResponse(this.root, generation, json, MAX_BYTES);
    // No slot access, including cleanup, after this call starts, even on error.
    await this.backend.makeDone(this.root, generation);
    return true;
  }

  // Safe to display for per-operation consent. It is a copy, not mutable state.
  describe(): MailboxPayload {
    if (this.request.payload.operation === 'open') {
      return { operation: 'open', url: this.request.payload.url };
    }
    return { operation: 'observe' };
  }
}

export class BrowserMailbox {
  private root: string;
  private backend: BrowserMailboxBackend;

  // There is deliberately no default adapter or automatic platform probing.
  constructor(root: string, verifiedBackend: BrowserMailboxBackend) {
    if (!root || !verifiedBackend) { throw new Error('verified backend and private root required'); }
    this.root = root;
    this.backend = verifiedBackend;
  }

  // One bounded inspection and claim, only after the user manually starts and
  // authorizes checking the mailbox. Null means no actionable request. Failure
  // never removes a slot or breaks an existing claim.
  async readAndClaim(): Promise<BrowserMailboxClaim | null> {
    const generation = await this.backend.listActive(this.root);
    if (generation === null) { return null; }
    if (!validGeneration(generation)) { throw new Error('invalid generation'); }
    const text = await this.backend.readRequest(this.root, generation, MAX_BYTES);
    if (text === null) { return null; }
    const request = parseRequest(text, generation);
    if (Date.now() >= request.deadline) { return null; }
    if (!await this.backend.tryClaim(this.root, generation)) { return null; }
    if (await this.backend.revoked(this.root, generation)) { return null; }
    if (Date.now() >= request.deadline) { return null; }
    return new BrowserMailboxClaim(this.backend, this.root, request);
  }
}
