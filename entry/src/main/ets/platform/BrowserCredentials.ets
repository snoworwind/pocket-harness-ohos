import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BrowserRelayReady } from './BrowserRelay';

/*
 * Opt-in native publisher; not wired into BrowserBridge. Example integration:
 * After device verification only: provide a native permission verifier to the
 * constructor. It must fail closed unless directories are private (0700 or
 * tighter) and files are private (0600 or tighter), with correct ownership.
 * host.deliverReady = (ready) => publisher.deliverReady(ready);
 * host.onClosed = () => publisher.stop();
 *
 * This API and mkdir/rename/lstat semantics have NOT been validated with the
 * ArkTS SDK or on device. Verify permissions and atomic rename before use.
 * filesDir must be private to the application; actual directory/file modes are
 * platform dependent, not guaranteed here. All same-UID code can read, replace,
 * or race these files: checks are not a defence against a malicious same-UID
 * process (no dirfd/openat). No page, argv, environment, or log gets secrets.
 * Readers MUST reject expiresAt <= Date.now(); timers can run late or not at all.
 */
interface CredentialDocument {
  version: number;
  host: string;
  port: number;
  credential: string;
  expiresAt: number;
}

let owner: BrowserCredentials | undefined;

function missing(error: Object): boolean {
  const e = error as BusinessErrorShape;
  return e.code === 13900002 || e.code === 'ENOENT';
}
interface BusinessErrorShape { code?: number | string; }

function exists(path: string): boolean {
  try { fs.lstatSync(path); return true; } catch (error) {
    if (missing(error as Object)) { return false; }
    throw new Error('Credential path inspection failed');
  }
}

function directory(path: string): void {
  const stat = fs.lstatSync(path);
  if (stat.isSymbolicLink() || !stat.isDirectory()) { throw new Error('Unsafe credential directory'); }
}

function regular(path: string): void {
  const stat = fs.lstatSync(path);
  if (stat.isSymbolicLink() || !stat.isFile()) { throw new Error('Unsafe credential file'); }
}

export class BrowserCredentials {
  private root: string;
  private dir: string;
  private target: string;
  private tempDir: string;
  private temp: string;
  private verifyPermissions?: (path: string, isDirectory: boolean) => boolean;
  private stopped: boolean = false;
  private used: boolean = false;
  private published: string = '';
  private timer: number = -1;

  // The verifier is trusted native code, not a web callback. It must be
  // implemented and validated for the device; there is no default verifier.
  constructor(filesDir: string, verifyPermissions?: (path: string, isDirectory: boolean) => boolean) {
    this.verifyPermissions = verifyPermissions;
    if (!filesDir.startsWith('/') || filesDir === '/' || filesDir.endsWith('/') ||
      filesDir.split('/').some((part: string, index: number): boolean =>
        index > 0 && (part === '' || part === '.' || part === '..'))) {
      throw new Error('Invalid files directory');
    }
    this.root = filesDir;
    this.dir = filesDir + '/browser-managed';
    this.target = this.dir + '/ready.json';
    this.tempDir = this.dir + '/ready.tmp';
    this.temp = this.tempDir + '/data';
  }

  private checkRoot(): void {
    let current = '';
    const parts = this.root.split('/');
    for (let i = 1; i < parts.length; i++) {
      current += '/' + parts[i];
      directory(current);
    }
  }

  private privatePath(path: string, isDirectory: boolean): void {
    const verify = this.verifyPermissions;
    if (!verify || !verify(path, isDirectory)) { throw new Error('Unverified credential permissions'); }
  }

  private checkDir(): void {
    this.checkRoot(); this.privatePath(this.root, true);
    directory(this.dir); this.privatePath(this.dir, true);
  }

  private removeEmptyTempDir(): void {
    this.checkDir(); directory(this.tempDir);
    // OHOS rmdirSync may recursively remove nonempty directories. Never call it
    // after observing an unexpected entry. A same-UID process can still race
    // listFileSync and rmdirSync; pathname checks cannot close that TOCTOU gap.
    if (fs.listFileSync(this.tempDir).length !== 0) { throw new Error('Temporary directory not empty'); }
    fs.rmdirSync(this.tempDir);
  }

  // All filesystem operations are synchronous: publish and stop cannot interleave
  // within this JS runtime. The promise matches BrowserBridgeHost.deliverReady.
  async deliverReady(ready: BrowserRelayReady): Promise<void> {
    if (!this.verifyPermissions || this.stopped || this.used || owner !== undefined) { throw new Error('Publisher unavailable'); }
    this.used = true;
    owner = this;
    let created = false;
    try {
      if (ready.host !== '127.0.0.1' || !Number.isInteger(ready.port) || ready.port < 1 || ready.port > 65535 ||
        typeof ready.credential !== 'string' || !/^[a-f0-9]{64}$/.test(ready.credential)) {
        throw new Error('Invalid relay readiness');
      }
      const now = Date.now();
      const document: CredentialDocument = { version: 1, host: '127.0.0.1', port: ready.port,
        credential: ready.credential, expiresAt: now + 300000 };
      const text = JSON.stringify(document);
      this.checkRoot(); this.privatePath(this.root, true);
      if (!exists(this.dir)) { fs.mkdirSync(this.dir); }
      this.checkDir();
      if (exists(this.target)) { regular(this.target); }
      // A non-recursive mkdir must fail if this path already exists. The fresh
      // directory reserves the temporary name without assuming an EXCL flag.
      // This still cannot withstand a hostile same-UID process replacing it.
      fs.mkdirSync(this.tempDir);
      created = true;
      directory(this.tempDir); this.privatePath(this.tempDir, true);
      if (exists(this.temp)) { throw new Error('Unsafe temporary file'); }
      const file = fs.openSync(this.temp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
      try {
        regular(this.temp); this.privatePath(this.temp, false);
        let offset = 0;
        // Relay credentials are ASCII in the protocol; JSON output may still
        // contain non-ASCII, so write UTF-8 bytes and handle short writes.
        const bytes = new util.TextEncoder().encodeInto(text);
        while (offset < bytes.length) {
          const count = fs.writeSync(file.fd, bytes.slice(offset).buffer);
          if (count <= 0 || count > bytes.length - offset) { throw new Error('Credential write failed'); }
          offset += count;
        }
      } finally { fs.closeSync(file); }
      this.checkDir();
      directory(this.tempDir);
      regular(this.temp);
      if (exists(this.target)) { regular(this.target); }
      if (this.stopped || Date.now() >= document.expiresAt) { throw new Error('Publisher expired'); }
      fs.renameSync(this.temp, this.target);
      this.published = text;
      this.removeEmptyTempDir();
      created = false;
      // Recheck immediately, including clock jumps and synchronous IO delays.
      if (this.stopped || Date.now() >= document.expiresAt) { throw new Error('Publisher expired'); }
      this.timer = setTimeout((): void => { this.stop(); }, Math.max(0, document.expiresAt - Date.now()));
    } catch (_error) {
      if (created) {
        try {
          this.checkDir(); directory(this.tempDir);
          if (exists(this.temp)) { regular(this.temp); fs.unlinkSync(this.temp); }
          this.removeEmptyTempDir();
        } catch (_ignored) { /* leave unsafe or nonempty paths untouched */ }
      }
      this.stop();
      throw new Error('Credential publication failed');
    }
  }

  stop(): void {
    if (this.stopped) { return; }
    this.stopped = true;
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    try {
      if (this.published !== '') {
        this.checkDir();
        if (exists(this.target)) {
          regular(this.target);
          if (fs.readTextSync(this.target) === this.published) { fs.unlinkSync(this.target); }
        }
      }
    } finally {
      this.published = '';
      if (owner === this) { owner = undefined; }
    }
  }
}
