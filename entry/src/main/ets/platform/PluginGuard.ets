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
interface QuarantineRecord {
  time: string;
  reason: string;
  // 实际移进隔离目录的包名。
  bundles: string[];
  // 隔离前的完整 bundle 列表：恢复时按它还原，目录缺失/移动失败的包也不会丢配置。
  originalBundles: string[];
  dir: string;
  // 隔离时没能移动的包及原因；恢复后仍要提示用户。
  failed: string[];
  // 是否已经由壳层自动尝试恢复过（每个安装只尝试一次）。
  autoRestored?: boolean;
}
interface QuarantineState {
  version: number;
  records: QuarantineRecord[];
}
interface QuarantineResult {
  moved: string[];
  error: string;
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
  // 自动恢复只尝试一次：写一个跨启动保留的标记，避免坏插件导致「隔离→自动恢复→
  // 再崩→再隔离」的循环。用户仍可在界面上手动恢复。
  private get autoRestoreMarker(): string { return this.home + '/.auto-restore-attempted'; }

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
    if (!manifest) { throw new Error('profile 的 package.json 缺失或无法解析'); }
    if (!manifest.dsh) { manifest.dsh = {}; }
    if (!manifest.dsh.profile) { manifest.dsh.profile = {}; }
    manifest.dsh.profile.bundles = names;
    // 先写同目录临时文件再 rename：中途失败也不会把原配置截断成空文件。
    const temporary = path + '.tmp';
    const file = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JSON.stringify(manifest, null, 2) + '\n');
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(temporary, path);
  }

  // 回滚用：尽力把配置写回原值，失败也不覆盖原始错误。
  private restoreBundlesQuietly(names: string[]): void {
    try { this.writeBundles(names); } catch (error) { /* 保留原始错误 */ }
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

  private quarantineSegment(name: string): string {
    return name.replace(/\//g, '+');
  }

  // 读取隔离记录；兼容旧版单条记录（顶层直接是 {dir,bundles,...}）。
  // 解析失败按「没有记录」处理，但调用方不能因此删除磁盘上的隔离目录。
  private readQuarantineRecords(): QuarantineRecord[] {
    const state = this.readJson(this.quarantineState);
    if (!state) { return []; }
    const records: QuarantineRecord[] = [];
    const list = state['records'];
    if (Array.isArray(list)) {
      for (const entry of list as QuarantineRecord[]) {
        if (!entry || typeof entry.dir !== 'string') { continue; }
        const bundles = Array.isArray(entry.bundles) ? entry.bundles : [];
        const original = Array.isArray(entry.originalBundles) ? entry.originalBundles : [];
        const failed = Array.isArray(entry.failed) ? entry.failed : [];
        records.push({
          time: typeof entry.time === 'string' ? entry.time : '',
          reason: typeof entry.reason === 'string' ? entry.reason : '',
          bundles: bundles,
          originalBundles: original,
          dir: entry.dir,
          failed: failed,
          autoRestored: entry.autoRestored === true
        });
      }
      return records;
    }
    const legacyDir = state['dir'];
    if (typeof legacyDir !== 'string' || legacyDir === '') { return []; }
    const legacyNames = Array.isArray(state['bundles']) ? state['bundles'] as string[] : [];
    // 旧记录没有保存原配置：只能按「内置 + 已隔离包」推断。
    records.push({
      time: typeof state['time'] === 'string' ? state['time'] as string : '',
      reason: typeof state['reason'] === 'string' ? state['reason'] as string : '',
      bundles: legacyNames,
      originalBundles: this.builtin().concat(legacyNames),
      dir: legacyDir,
      failed: []
    });
    return records;
  }

  private writeQuarantineRecords(records: QuarantineRecord[]): void {
    const state: QuarantineState = { version: 2, records: records };
    const temporary = this.quarantineState + '.tmp';
    const file = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JSON.stringify(state, null, 2) + '\n');
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(temporary, this.quarantineState);
  }

  /** 安全模式：把第三方 bundle 全部隔离，只留内置集合。返回被隔离的包名与失败原因。 */
  quarantine(reason: string): QuarantineResult {
    const original = this.bundles();
    const names = original.filter((name: string) => this.builtin().indexOf(name) < 0);
    if (names.length === 0) { return { moved: [], error: '' }; }
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    const target = this.quarantineRoot + '/' + stamp;
    try {
      this.ensureDir(target);
    } catch (error) {
      return { moved: [], error: '无法创建隔离目录：' + (error as Error).message };
    }
    const moved: string[] = [];
    const failed: string[] = [];
    for (const name of names) {
      const from = this.home + '/profiles/web/node_modules/' + name;
      if (!fs.accessSync(from)) {
        failed.push(name + '：包目录不存在');
        continue;
      }
      try {
        fs.renameSync(from, target + '/' + this.quarantineSegment(name));
        moved.push(name);
      } catch (error) {
        failed.push(name + '：移动失败（' + (error as Error).message + '）');
      }
    }
    if (moved.length === 0) {
      // 一个都没移动成功：配置保持原样，否则包还在、profile 里却没了。
      try { this.removeTree(target); } catch (error) { /* 空目录清理失败无影响 */ }
      return { moved: [], error: failed.join('；') };
    }
    // 没隔离成功的包继续留在配置里：它们可能仍能启动，不能顺手丢配置。
    const kept = names.filter((name: string) => moved.indexOf(name) < 0);
    const next = this.builtin().concat(kept);
    const record: QuarantineRecord = {
      time: stamp, reason: reason, bundles: moved, originalBundles: original,
      dir: target, failed: failed
    };
    try {
      this.writeBundles(next);
      this.writeQuarantineRecords(this.readQuarantineRecords().concat([record]));
    } catch (error) {
      // 配置或隔离记录没写成功：把配置和已移动的包都回滚，保证三者一致。
      this.restoreBundlesQuietly(original);
      for (const name of moved) {
        try {
          fs.renameSync(target + '/' + this.quarantineSegment(name),
            this.home + '/profiles/web/node_modules/' + name);
        } catch (rollbackError) { /* 尽力而为 */ }
      }
      return { moved: [], error: '隔离状态写入失败，已回滚：' + (error as Error).message };
    }
    return { moved: moved, error: failed.join('；') };
  }

  /**
   * 有隔离记录时恢复：把所有隔离记录里的包移回 profile，并还原隔离前的完整
   * bundle 列表。任何一步失败都保留记录、返回错误，用户可以重试。
   */
  restoreLastQuarantine(): string {
    const records = this.readQuarantineRecords();
    if (records.length === 0) { return '没有可恢复的隔离记录'; }
    const failed: string[] = [];
    // 先只搬文件，不动配置：搬失败时记录仍然有效。
    for (const record of records) {
      for (const name of record.bundles) {
        const from = record.dir + '/' + this.quarantineSegment(name);
        const to = this.home + '/profiles/web/node_modules/' + name;
        if (!fs.accessSync(from)) {
          // 上次恢复到一半（文件已搬回、配置没写成）时视为已恢复。
          if (fs.accessSync(to)) { continue; }
          failed.push(name + '：隔离目录里找不到（' + from + '）');
          continue;
        }
        try {
          this.ensureDir(to.slice(0, to.lastIndexOf('/')));
          fs.renameSync(from, to);
        } catch (error) {
          failed.push(name + '：移回失败（' + (error as Error).message + '）');
        }
      }
    }
    if (failed.length > 0) {
      return '恢复未完成，隔离记录已保留（可重试）：' + failed.join('；');
    }
    let original = records[0].originalBundles;
    if (original.length === 0) {
      // 旧记录没有原配置：退回「内置 + 所有记录里的包」。
      const all: string[] = [];
      for (const record of records) {
        for (const name of record.bundles) {
          if (all.indexOf(name) < 0) { all.push(name); }
        }
      }
      original = this.builtin().concat(all);
    }
    try {
      this.writeBundles(original);
    } catch (error) {
      // 配置没写成：把刚搬回来的包再放回隔离目录，让记录和磁盘保持一致。
      for (const record of records) {
        for (const name of record.bundles) {
          const from = this.home + '/profiles/web/node_modules/' + name;
          const to = record.dir + '/' + this.quarantineSegment(name);
          try {
            if (fs.accessSync(from) && !fs.accessSync(to)) { fs.renameSync(from, to); }
          } catch (rollbackError) { /* 尽力而为 */ }
        }
      }
      return '写入 profile 失败，已回滚：' + (error as Error).message;
    }
    try {
      fs.unlinkSync(this.quarantineState);
    } catch (error) {
      // 插件与配置都已恢复；记录删不掉只会让下次恢复提示失败，不阻塞启动。
      return '插件已恢复，但隔离记录删除失败：' + (error as Error).message;
    }
    // 隔离目录空了就一并清掉，避免占空间。
    for (const record of records) {
      try { if (fs.listFileSync(record.dir).length === 0) { fs.rmdirSync(record.dir); } }
      catch (error) { /* 目录非空或已不存在 */ }
    }
    return '';
  }

  hasQuarantine(): boolean {
    try { return fs.accessSync(this.quarantineState); } catch (error) { return false; }
  }

  /** 当前隔离记录里共有多少个包（用于界面提示）。 */
  quarantineCount(): number {
    let count = 0;
    for (const record of this.readQuarantineRecords()) { count += record.bundles.length; }
    return count;
  }

  /**
   * 是否可以把这次隔离自动恢复掉：
   * - 只处理「上次启动未完成」这种崩溃/看门狗导致的隔离；插件自身 import 失败的
   *   隔离不自动恢复，避免重新把引擎弄挂；
   * - 每次安装只自动尝试一次（`.auto-restore-attempted` 跨启动保留）。
   */
  canAutoRestore(): boolean {
    try { if (fs.accessSync(this.autoRestoreMarker)) { return false; } } catch (error) { /* 未尝试过 */ }
    const records = this.readQuarantineRecords();
    if (records.length === 0) { return false; }
    for (const record of records) {
      if (record.reason.indexOf('上次启动未完成') < 0) { return false; }
      if (record.autoRestored === true) { return false; }
    }
    return true;
  }

  markAutoRestoreAttempted(): void {
    try {
      const file = fs.openSync(this.autoRestoreMarker, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, Date.now().toString());
      fs.closeSync(file);
    } catch (error) { /* 标记失败最多多试一次 */ }
    const records = this.readQuarantineRecords();
    for (const record of records) { record.autoRestored = true; }
    try { this.writeQuarantineRecords(records); } catch (error) { /* 尽力而为 */ }
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
