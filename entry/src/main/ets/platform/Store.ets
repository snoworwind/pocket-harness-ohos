import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { asset } from '@kit.AssetStoreKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Session, Settings, Workspace, defaults } from '../core/Types';
import { safePath } from '../core/Tools';

interface Snapshot { version: number; settings: Settings; sessions: Session[] }
export class Store {
  settings: Settings = defaults();
  sessions: Session[] = [];
  root: string;
  constructor(context: common.UIAbilityContext) { this.root = context.filesDir; }
  load(): void {
    const path = this.root + '/state.json';
    if (!fs.accessSync(path)) { return; }
    const data = JSON.parse(fs.readTextSync(path)) as Snapshot;
    if (data.version !== 1 || !Array.isArray(data.sessions) || !data.settings) { throw new Error('会话存档格式不受支持'); }
    this.settings = data.settings;
    this.sessions = data.sessions;
    // Recover interrupted tool groups after process death without replaying mutations.
    for (const session of this.sessions) {
      for (let i = 0; i < session.messages.length; i++) {
        const msg = session.messages[i];
        if (!msg.tool_calls) { continue; }
        const missing = msg.tool_calls.filter((call) => !session.messages.some((m) => m.role === 'tool' && m.tool_call_id === call.id));
        let insert = i + 1;
        while (insert < session.messages.length && session.messages[insert].role === 'tool') { insert++; }
        for (const call of missing) {
          session.messages.splice(insert++, 0, { role: 'tool', tool_call_id: call.id, content: '应用曾中断，工具结果未知。请先读取文件确认，不能假定写入成功或自动重复写入。' });
        }
      }
    }
  }
  save(): void {
    const snapshot: Snapshot = { version: 1, settings: this.settings, sessions: this.sessions };
    atomicWrite(this.root + '/state.json', JSON.stringify(snapshot));
  }
  workspace(id: string): NativeWorkspace {
    if (!/^[a-z0-9]+$/.test(id)) { throw new Error('会话 ID 无效'); }
    const root = this.root + '/workspaces/' + id;
    fs.mkdirSync(root, true);
    return new NativeWorkspace(root);
  }
  workspacePath(id: string): string {
    this.workspace(id);
    return this.root + '/workspaces/' + id;
  }
}
function atomicWrite(path: string, text: string): void {
  const file = fs.openSync(path + '.tmp', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    const bytes = new util.TextEncoder().encodeInto(text);
    let offset = 0;
    while (offset < bytes.length) {
      const count = fs.writeSync(file.fd, bytes.slice(offset).buffer);
      if (count <= 0) { throw new Error('文件写入未完成'); }
      offset += count;
    }
    fs.fsyncSync(file.fd);
  } finally { fs.closeSync(file); }
  fs.renameSync(path + '.tmp', path);
}
export class NativeWorkspace implements Workspace {
  private root: string;
  constructor(root: string) { this.root = root; }
  private resolve(relative: string, rootAllowed: boolean = false): string {
    const safe = safePath(relative, rootAllowed);
    let current = this.root;
    for (const part of safe.split('/').filter((p: string) => p.length > 0)) {
      current += '/' + part;
      if (fs.accessSync(current) && fs.lstatSync(current).isSymbolicLink()) { throw new Error('工作区不允许符号链接'); }
    }
    return current;
  }
  async list(path: string): Promise<string> {
    const resolved = this.resolve(path || '.', true);
    return JSON.stringify(fs.listFileSync(resolved, { recursion: false, listNum: 200 }));
  }
  async read(path: string): Promise<string> {
    const resolved = this.resolve(path);
    if (!fs.accessSync(resolved)) { return '__HARNESS_FILE_NOT_FOUND__'; }
    const stat = fs.statSync(resolved);
    if (!stat.isFile() || stat.size > 65536) { throw new Error('只能读取不超过 64 KiB 的普通文本文件'); }
    return fs.readTextSync(resolved);
  }
  async write(path: string, content: string): Promise<string> {
    if (new util.TextEncoder().encodeInto(content).length > 65536) { throw new Error('文件超过 64 KiB'); }
    const resolved = this.resolve(path);
    const parent = resolved.slice(0, resolved.lastIndexOf('/'));
    fs.mkdirSync(parent, true);
    this.resolve(path + '.tmp');
    atomicWrite(resolved, content);
    return '文件已保存：' + path;
  }
}
export class KeyStore {
  private alias(): Uint8Array { return new util.TextEncoder().encodeInto('deepseek-harmony-provider-key'); }
  async save(key: string): Promise<void> {
    const attrs: asset.AssetMap = new Map();
    attrs.set(asset.Tag.ALIAS, this.alias());
    if (key.length === 0) { await asset.remove(attrs); return; }
    attrs.set(asset.Tag.SECRET, new util.TextEncoder().encodeInto(key));
    attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
    attrs.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    await asset.add(attrs);
  }
  async read(): Promise<string> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, this.alias());
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const rows = await asset.query(query);
      if (rows.length === 0) { return ''; }
      const secret = rows[0].get(asset.Tag.SECRET) as Uint8Array;
      return util.TextDecoder.create('utf-8').decodeToString(secret);
    } catch (error) {
      if ((error as BusinessError).code === 24000002) { return ''; }
      throw new Error('无法读取安全凭据，请解锁设备并检查 Asset Store');
    }
  }
}
