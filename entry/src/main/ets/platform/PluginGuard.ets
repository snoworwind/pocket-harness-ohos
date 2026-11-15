import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

interface ProfileManifest {
  dependencies?: Record<string, string>;
  dsh?: ProfileDsh;
}
interface ProfileDsh {
  profile?: ProfileBundles;
}
interface ProfileBundles {
  bundles?: string[];
}
interface QuarantineState {
  time: string;
  reason: string;
  bundles: string[];
  dir: string;
}

// 用户插件的守门人。
//
// 用户插件装在 `filesDir/harness-home/profiles/web`（profile 层），这个目录跨升级保留，
// 所以插件能跟着升级走；代价是插件一旦和新引擎不兼容，`dsh web` 会整体起不来，
// 而清运行时目录没用。这里做三件事：
//   1. 启动前记一笔“正在启动”，起来后清掉；下次启动看到这笔就说明上次没起来，
//      先按安全模式（只留内置 bundle）启动，保证用户还能进界面处理；
//   2. 隔离：把第三方 bundle 目录移到 plugin-quarantine/<时间>/，并把 profile
//      的 bundle 列表改回内置集合，可一键恢复；
//   3. 体检：缺失目录、坏 package.json、patch 文件不存在、`.node` 不是 AArch64，
//      都在进引擎前就能报出来。
export class PluginGuard {
  private context: common.UIAbilityContext;
  constructor(context: common.UIAbilityContext) { this.context = context; }

  private get home(): string { return this.context.filesDir + '/harness-home'; }
  private get profile(): string { return this.home + '/profiles/web'; }
  private get marker(): string { return this.home + '/.boot-in-progress'; }
  private get quarantineState(): string { return this.home + '/plugin-quarantine.json'; }
  private get quarantineRoot(): string { return this.home + '/plugin-quarantine'; }

  private builtin(): string[] { return ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app']; }

  private readJson(path: string): Record<string, Object> | undefined {
    try {
      if (!fs.accessSync(path)) { return undefined; }
      return JSON.parse(fs.readTextSync(path)) as Record<string, Object>;
    } catch (error) { return undefined; }
  }

  private bundles(): string[] {
    const manifest = this.readJson(this.profile + '/package.json') as ProfileManifest | undefined;
    return manifest?.dsh?.profile?.bundles ?? [];
  }

  private writeBundles(names: string[]): void {
    const path = this.profile + '/package.json';
    const manifest = this.readJson(path) as ProfileManifest | undefined;
    if (!manifest) { return; }
    if (!manifest.dsh) { manifest.dsh = {}; }
    if (!manifest.dsh.profile) { manifest.dsh.profile = {}; }
    manifest.dsh.profile.bundles = names;
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, JSON.stringify(manifest, null, 2) + '\n');
    fs.closeSync(file);
  }

  private thirdPartyBundles(): string[] {
    const builtin = this.builtin();
    return this.bundles().filter((name: string) => builtin.indexOf(name) < 0);
  }

  /** 记录「开始启动」；成功拿到 URL 后必须调用 markBootSucceeded。 */
  markBootStarted(): void {
    try {
      const file = fs.openSync(this.marker, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, Date.now().toString());
      fs.closeSync(file);
    } catch (error) { /* 标记失败不影响启动 */ }
  }

  markBootSucceeded(): void {
    try { if (fs.accessSync(this.marker)) { fs.unlinkSync(this.marker); } } catch (error) { /* 忽略 */ }
  }

  /** 上次启动是否没走完（有标记说明上次引擎没起来）。 */
  lastBootFailed(): boolean {
    try { return fs.accessSync(this.marker); } catch (error) { return false; }
  }

  /** 安全模式：把第三方 bundle 全部隔离，只留内置集合。返回被隔离的包名。 */
  quarantine(reason: string): string[] {
    const names = this.thirdPartyBundles();
    if (names.length === 0) { return []; }
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    const target = this.quarantineRoot + '/' + stamp;
    this.ensureDir(target);
    const moved: string[] = [];
    for (const name of names) {
      const from = this.home + '/profiles/web/node_modules/' + name;
      if (!fs.accessSync(from)) { continue; }
      try {
        fs.renameSync(from, target + '/' + name.replace(/\//g, '+'));
        moved.push(name);
      } catch (error) { /* 单个包移动失败就留着，最多再失败一次 */ }
    }
    this.writeBundles(this.builtin());
    const state: QuarantineState = { time: stamp, reason: reason, bundles: moved, dir: target };
    try {
      const file = fs.openSync(this.quarantineState, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(state, null, 2) + '\n');
      fs.closeSync(file);
    } catch (error) { /* 状态写不进去，至少 bundle 列表已经清了 */ }
    return moved;
  }

  /** 有隔离记录时，恢复上次隔离掉的插件并还原 bundle 列表。 */
  restoreLastQuarantine(): boolean {
    const state = this.readJson(this.quarantineState);
    if (!state) { return false; }
    const dir = state.dir as string;
    const names = (state.bundles as string[]) ?? [];
    for (const name of names) {
      const from = dir + '/' + name.replace(/\//g, '+');
      const to = this.home + '/profiles/web/node_modules/' + name;
      if (!fs.accessSync(from)) { continue; }
      this.ensureDir(to.slice(0, to.lastIndexOf('/')));
      try { fs.renameSync(from, to); } catch (error) { /* 单个失败继续 */ }
    }
    const next = this.builtin().concat(names);
    this.writeBundles(next);
    try { fs.unlinkSync(this.quarantineState); } catch (error) { /* 忽略 */ }
    return true;
  }

  hasQuarantine(): boolean {
    try { return fs.accessSync(this.quarantineState); } catch (error) { return false; }
  }

  /**
   * 进引擎前的体检：第三方 bundle 的目录/清单/patch 是否存在，
   * 以及随包的 `.node` 是不是 AArch64（x86/glibc 预编译包一律报出来）。
   */
  inspect(): string[] {
    const problems: string[] = [];
    for (const name of this.thirdPartyBundles()) {
      const dir = this.home + '/profiles/web/node_modules/' + name;
      if (!fs.accessSync(dir)) { problems.push(name + '：profile 里没有这个包目录'); continue; }
      const manifest = this.readJson(dir + '/package.json');
      if (!manifest) { problems.push(name + '：package.json 缺失或无法解析'); continue; }
      const patches = (manifest as Record<string, Object>)['dsh'];
      const bundle = patches ? (patches as Record<string, Object>)['bundle'] : undefined;
      const list = bundle ? ((bundle as Record<string, Object>)['patch'] as string[]) : undefined;
      if (list) {
        for (const patch of list) {
          if (!fs.accessSync(dir + '/' + patch.replace(/^\.\//, ''))) { problems.push(name + '：缺少 patch 文件 ' + patch); }
        }
      }
      this.inspectNative(dir, name, problems);
    }
    return problems;
  }

  private inspectNative(dir: string, name: string, problems: string[]): void {
    try {
      for (const entry of fs.listFileSync(dir)) {
        const path = dir + '/' + entry;
        const stat = fs.lstatSync(path);
        if (stat.isDirectory()) {
          if (entry !== 'node_modules' || true) { this.inspectNative(path, name, problems); }
          continue;
        }
        if (!entry.endsWith('.node')) { continue; }
        const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
        const head = new Uint8Array(20);
        fs.readSync(file.fd, head);
        fs.closeSync(file);
        if (head[0] !== 0x7f || head[1] !== 0x45 || head[2] !== 0x4c || head[3] !== 0x46) {
          problems.push(name + '：' + entry + ' 不是 ELF 文件');
          continue;
        }
        // e_machine 在偏移 18，小端 0xB7 = AArch64
        const machine = head[18] | (head[19] << 8);
        if (machine !== 0xb7) { problems.push(name + '：' + entry + ' 不是 arm64（e_machine=' + machine.toString(16) + '）'); }
      }
    } catch (error) { /* 目录读不动就跳过体检 */ }
  }

  /** profile 备份，保留最近 3 份。用于升级或大改动前留退路。 */
  backup(): void {
    try {
      const root = this.home + '/backups';
      this.ensureDir(root);
      const stamp = new Date().toISOString().replace(/[:.]/g, '-');
      this.copyTree(this.profile, root + '/web-' + stamp);
      const names = fs.listFileSync(root).filter((name: string) => name.indexOf('web-') === 0).sort();
      while (names.length > 3) {
        const oldest = names.shift() as string;
        this.removeTree(root + '/' + oldest);
      }
    } catch (error) { /* 备份失败不阻塞启动 */ }
  }

  private ensureDir(path: string): void {
    if (!fs.accessSync(path)) { fs.mkdirSync(path, true); }
  }

  private copyTree(from: string, to: string): void {
    this.ensureDir(to);
    for (const name of fs.listFileSync(from)) {
      const src = from + '/' + name;
      const dst = to + '/' + name;
      if (fs.lstatSync(src).isDirectory()) { this.copyTree(src, dst); continue; }
      fs.copyFileSync(src, dst);
    }
  }

  private removeTree(path: string): void {
    if (!fs.accessSync(path)) { return; }
    if (!fs.lstatSync(path).isDirectory()) { fs.unlinkSync(path); return; }
    for (const name of fs.listFileSync(path)) { this.removeTree(path + '/' + name); }
    fs.rmdirSync(path);
  }
}
