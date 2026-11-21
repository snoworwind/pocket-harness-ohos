import { common } from '@kit.AbilityKit';
import { fileIo as fs, hash } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { execStart, execPoll, execWrite, execCloseStdin, execTerminate, execRelease,
  initIecResourceManager, installCaBundle, installRawfileFile, probeCaps, startIecServer, unpackResource,
  writeSoLauncher, writeTxtFile } from 'iec';
import { EngineHooks, EnginePipe, OfficialRpc } from '../core/OfficialRpc';
import { Settings } from '../core/Types';

interface NativeCommand { name: string; library: string; entry: string; arity?: number }
interface RuntimeManifest { version: string; engineVersion: string; nodeVersion: string; commands: NativeCommand[] }
interface ServerIdentity { serverInfo: ServerInfo }
interface ServerInfo { name: string; version: string }
// .installed 的新格式；旧版本这里只有一行 manifest.version 文本。
interface InstalledRecord { version: string; schema: number; manifestSha256: string; files: Record<string, string> }

function pause(ms: number): Promise<void> { return new Promise<void>((resolve) => { setTimeout(resolve, ms); }); }

// 启动时抽查的运行时文件（相对 runtime-<版本> 根目录）。只挑体积小且启动必经的
// 文件：node/bash 是文本启动器，bin.js 是 Web 服务入口。libnode.so 等 ELF 在只读
// bundle 目录、由包管理器负责完整性，且体积大，不放进每次启动的抽样范围。
// 本仓库没有 bin/dsh 启动器：Web GUI 走 bin/node + engine/.../lib/bin.js。
const INTEGRITY_FILES: string[] = [
  'engine/node_modules/@deepseek-ai/dsh/lib/bin.js',
  'engine/node_modules/@deepseek-ai/dsh/package.json',
  'bin/node',
  'bin/bash',
  'npm/bin/npm-cli.js',
  'python/lib/python3.12/os.py'
];
// .installed 结构版本；格式变更时必须递增，旧记录会因 schema 不符触发一次重解。
const INSTALLED_SCHEMA = 2;
const LOG_ROTATE_BYTES = 4 * 1024 * 1024;
const LOG_BACKUP_COUNT = 2;
// 旧运行时目录切片删除时，目录的第二次访问用这个不可见后缀标记。
const PRUNE_REVISIT = '\u0000';

// 日志落盘前的统一脱敏（纯函数，Node 侧可单独 transpile 后测试）。
// 只替换值、保留键名，避免把 token/Authorization/密钥写进诊断包。
export function redactLogText(text: string): string {
  if (text.length === 0) { return text; }
  let out = text;
  // Authorization 头（含 Basic/Bearer/Token 等任意值形态）；值到行尾或引号为止。
  out = out.replace(/(authorization\s*:\s*)([^\r\n"']+)/gi, '$1***');
  // 只出现 header 值时仍可能以 "Bearer xxx" 形式被打印。
  out = out.replace(/(bearer\s+)[A-Za-z0-9._~+/=-]+/gi, '$1***');
  // JSON/带引号的键："token": "..."、"password": "..."。
  out = out.replace(/("(?:[A-Za-z0-9_.-]*(?:token|password|secret|api[_-]?key|access[_-]?key|private[_-]?key))"\s*:\s*")([^"]*)(")/gi, '$1***$3');
  // 键不带引号但值是引号包起来的：password: "..." / secret = '...'。
  out = out.replace(/([A-Za-z0-9_.-]*(?:token|password|secret|api[_-]?key|access[_-]?key|private[_-]?key)[A-Za-z0-9_.-]*\s*[=:]\s*")([^"]*)(")/gi, '$1***$3');
  out = out.replace(/([A-Za-z0-9_.-]*(?:token|password|secret|api[_-]?key|access[_-]?key|private[_-]?key)[A-Za-z0-9_.-]*\s*[=:]\s*')([^']*)(')/gi, "$1***$3");
  // key=value / key: value（URL query、环境变量、命令行赋值）：值截到分隔符。
  out = out.replace(/(^|[^A-Za-z0-9])([A-Za-z0-9_.-]*(?:token|password|secret|api[_-]?key|access[_-]?key|private[_-]?key)[A-Za-z0-9_.-]*\s*[=:]\s*)([^\s&,;"'\\]+)/gi, '$1$2***');
  return out;
}

// 唯一进程入口是 IEC；没有 adb、Linux rootfs 或设备外服务器回退。
export class NativeProcess implements EnginePipe {
  private id: number;
  private timer: number = -1;
  private ended: boolean = false;
  private stopping: boolean = false;
  private writes: Promise<void> = Promise.resolve();
  private decoder = util.TextDecoder.create('utf-8');
  private errDecoder = util.TextDecoder.create('utf-8');
  private base64 = new util.Base64Helper();
  private stderr: string = '';
  private output: (text: string) => void;
  private errorOutput?: (text: string) => void;
  private exit: (code: number, error: string) => void;
  constructor(command: string, args: string[], cwd: string, env: Record<string, string>,
    output: (text: string) => void, exit: (code: number, error: string) => void,
    errorOutput?: (text: string) => void) {
    this.output = output; this.exit = exit;
    this.errorOutput = errorOutput;
    const handle = execStart({ cmd: command, args: args, cwd: cwd, env: env, envReplace: true,
      keepStdinOpen: true, timeoutMs: 0, maxOutputBytes: 67108864 });
    this.id = handle.id;
    this.timer = setInterval(() => this.poll(), 30);
  }
  private poll(): void {
    if (this.ended) { return; }
    try {
      const chunk = execPoll(this.id, 65536, 65536, 'base64');
      if (chunk.outDropped > 0 || chunk.errDropped > 0) { this.close(); throw new Error('原生进程输出超限，连接已停止'); }
      if (chunk.out) { this.output(this.decoder.decodeToString(this.base64.decodeSync(chunk.out), { stream: true })); }
      if (chunk.err) {
        const errorText = this.errDecoder.decodeToString(this.base64.decodeSync(chunk.err), { stream: true });
        this.stderr = (this.stderr + errorText).slice(-16000);
        this.errorOutput?.(errorText);
      }
      if (!chunk.running && chunk.outEof && chunk.errEof) {
        this.output(this.decoder.decodeToString(new Uint8Array(0), { stream: false }));
        this.ended = true; clearInterval(this.timer); execRelease(this.id);
        this.exit(chunk.code, this.stderr);
      }
    } catch (error) {
      this.close(); this.ended = true; clearInterval(this.timer);
      this.exit(-1, (error as Error).message);
    }
  }
  write(line: string): Promise<void> {
    const task = this.writes.then(async () => {
      // JSON-RPC 层将字符串编码成 ASCII 转义，字节偏移与字符串偏移保持一致。
      if (/[^\x00-\x7f]/.test(line)) { throw new Error('原生协议输入必须使用 JSON ASCII 转义'); }
      let offset = 0; const started = Date.now();
      while (offset < line.length) {
        if (this.ended || this.stopping) { throw new Error('原生进程已停止'); }
        const count = execWrite(this.id, line.slice(offset, offset + 32768));
        if (count < 0) { throw new Error('原生进程输入已关闭'); }
        offset += count;
        if (Date.now() - started > 30000) { throw new Error('原生进程输入超时，不能自动重发'); }
        if (count === 0) { await pause(10); }
      }
    });
    this.writes = task.catch(() => { /* 单次写失败由调用方处理，后续关闭不产生未处理拒绝。 */ });
    return task;
  }
  close(): void {
    if (this.ended || this.stopping) { return; }
    this.stopping = true; execCloseStdin(this.id); execTerminate(this.id, 300);
  }
}

export class NativeRuntime {
  private context: common.UIAbilityContext;
  private root: string = '';
  private libraries: string = '';
  private ready: boolean = false;
  private rpc?: OfficialRpc;
  private process?: NativeProcess;
  private terminal?: NativeProcess;
  private shell?: NativeProcess;
  private web?: NativeProcess;
  private webUrl: string = '';
  private owned: Set<string> = new Set<string>();
  private env: Record<string, string> = {};
  private installing: boolean = false;
  // 日志轮转用的累计字节数：只在本进程内维护，启动时 stat 一次，
  // 避免每次 appendLog 都 stat（引擎 stdout 很频繁）。
  private logBytes: Record<string, number> = {};
  private logEncoder = new util.TextEncoder();
  engineVersion: string = '';
  // 终端页复用同一个运行时实例：ensure() 已经做过 probeCaps/startIecServer，
  // 再 new 一个实例会在 UI 线程重复探测，造成输入阻塞。
  get rootDir(): string { return this.root; }
  get environment(): Record<string, string> { return this.env; }
  // 当前是否在整棵解包/重装运行时：启动页据此决定要不要提示「首次启动」。
  get isInstalling(): boolean { return this.installing; }
  constructor(context: common.UIAbilityContext) { this.context = context; }
  async ensure(onInstalling?: (active: boolean) => void): Promise<void> {
    if (this.ready) { return; }
    const manifest = JSON.parse(util.TextDecoder.create('utf-8').decodeToString(
      this.context.resourceManager.getRawFileContentSync('tools/runtime-manifest.json'))) as RuntimeManifest;
    if (!/^[a-zA-Z0-9.-]+$/.test(manifest.version)) { throw new Error('原生运行时清单无效'); }
    this.root = this.context.filesDir + '/runtime-' + manifest.version;
    const libraries = this.nativeLibraryDirectory();
    this.libraries = libraries;
    for (const command of manifest.commands) {
      if (!/^[a-z0-9+_.-]+$/.test(command.name) || !/^lib[a-zA-Z0-9+_.-]+\.so$/.test(command.library) ||
        !fs.accessSync(libraries + command.library)) { throw new Error('缺少原生工具：' + command.name); }
    }
    initIecResourceManager(this.context.resourceManager);
    const caps = probeCaps();
    if (caps.fork === 0) { throw new Error('此设备未通过原生进程创建探针，不启动替代运行时'); }
    // 上次进程被强杀/覆盖安装时，原生执行服务可能还活着并占着 socket；
    // 先删掉残留的 socket 文件，新进程就能重新 bind（旧进程只是守着旧 inode）。
    for (const name of ['iec-tty.sock', 'iec-exec.sock']) {
      try { fs.unlinkSync(`/data/storage/el2/base/files/${name}`); } catch (error) { /* 不存在即可 */ }
    }
    if (!startIecServer()) { throw new Error('原生终端执行服务启动失败'); }
    this.ensureDir(this.root);
    this.ensureDir(this.root + '/bin');
    this.ensureDir(this.root + '/home');
    this.ensureDir(this.root + '/tmp');
    this.ensureDir(this.context.filesDir + '/harness-home');
    this.installBuiltinAgents();
    this.ensureDir(this.context.filesDir + '/home');
    this.ensureDir(this.context.filesDir + '/home/.ssh');
    this.ensureDir(this.context.filesDir + '/home/.config');
    this.ensureDir(this.context.filesDir + '/home/.cache');
    this.ensureDir(this.context.filesDir + '/tmp');
    // 启动时的完整性检查：.installed 保存版本号 + 关键文件的 SHA-256 清单。
    // 构建期清单（scripts/runtime-manifest.mjs）只按归档/so 字节算版本号，
    // 没有逐文件摘要，所以清单由应用在安装完成时按实际落盘文件计算并写入；
    // 启动时抽查关键文件，能发现安装后同 UID 对运行时的篡改。
    // 旧版 .installed 只有一行版本号：无法确认现有文件是否被改过，按未安装处理
    // （fail-closed，整棵重解一次），不把未知状态“补写”成可信基线。
    // 存在性检查保留，用于半棵树（解包中断、沙箱被清一部分）自愈。
    // 校验失败/文件缺失都只重解运行时，不删除 harness-home 用户数据。
    this.prepareLogs();
    let complete = false;
    const installed = this.readInstalled();
    if (installed !== undefined && installed.version === manifest.version) {
      complete = fs.accessSync(this.root + '/engine/node_modules/@deepseek-ai/dsh/lib/bin.js') &&
        fs.accessSync(this.root + '/npm/bin/npm-cli.js') &&
        fs.accessSync(this.root + '/python/lib/python3.12/os.py') &&
        fs.accessSync(this.root + '/vim/runtime/defaults.vim') &&
        await this.verifyInstalled(installed);
    }
    // 启动页据此决定是否提示「首次启动需要解包」，只有这里为 true 时才是真在解包。
    this.installing = !complete;
    if (!complete) {
      // 解包是同步阻塞调用，会卡住 UI 线程；先把「正在解包」状态交给界面并
      // 让出一帧，否则 300ms 的轮询永远看不到 installing=true，提示就成了死代码。
      if (onInstalling !== undefined) {
        onInstalling(true);
        await pause(300);
      }
      // 标记与解包结果对不上：整棵运行时重来，而不是只补 engine。
      this.removeTree(this.root);
      this.ensureDir(this.root);
      this.ensureDir(this.root + '/bin');
      this.ensureDir(this.root + '/home');
      this.ensureDir(this.root + '/tmp');
      this.ensureDir(this.root + '/engine');
      const engineCode = await unpackResource('tools/official-engine.tar.gz', this.root + '/engine');
      if (engineCode !== 0) {
        this.removeTree(this.root + '/engine');
        throw new Error('官方引擎解包失败（unpackResource=' + engineCode.toString() + '）');
      }
      const npmCode = await unpackResource('tools/npm.tar.gz', this.root);
      if (npmCode !== 0) { throw new Error('npm 解包失败（unpackResource=' + npmCode.toString() + '）'); }
      const pythonCode = await unpackResource('tools/python-stdlib.tar', this.root);
      if (pythonCode !== 0) { throw new Error('Python 标准库解包失败（unpackResource=' + pythonCode.toString() + '）'); }
      this.ensureDir(this.root + '/vim');
      const vimCode = await unpackResource('tools/vim-runtime.tar.gz', this.root + '/vim');
      if (vimCode !== 0) { throw new Error('Vim 运行时解包失败（unpackResource=' + vimCode.toString() + '）'); }
    }
    this.installing = false;
    if (onInstalling !== undefined) { onInstalling(false); }
    // git 的 init 模板目录：缺省会去找 /usr/share/git-core/templates（假根里不存在），
    // 每次 `git init` 都打印 "templates not found"。必须放在首次解包之后建，
    // 否则整棵运行时被 removeTree 后会漏掉。
    this.ensureDir(this.root + '/git-templates/hooks');
    this.ensureDir(this.root + '/git-templates/info');
    this.ensureDir(this.root + '/git-templates/branches');
    for (const command of manifest.commands) {
      // bash 的入口是 main(argc, argv, envp) 三参形状；按 2 参调用会把 envp 留成
      // 寄存器垃圾，bash 初始化变量时立刻崩溃。其余命令都是两参入口。
      const arity = command.arity === 3 ? 3 : 2;
      if (writeSoLauncher(this.root + '/bin/' + command.name, libraries + command.library, command.entry, arity) !== 0) {
        throw new Error('命令启动器写入失败：' + command.name);
      }
    }
    installCaBundle(this.root + '/certs');
    this.installTrustBundle();
    this.installOpensslConfig();
    this.installFetchPolyfill();
    this.installRuntimePreload();
    // 安装/重解成功后才写标记：清单里的哈希对应最终字节，写标记前任何一步失败
    // 都会让下次启动重新解包。已通过校验的启动不重写，避免每次开机重复哈希。
    if (!complete) { await this.writeInstalled(manifest); }
    this.env = this.buildEnv();
    const applets = await this.capture('toybox', ['--long']);
    for (const item of applets.split(/\s+/)) {
      const name = item.slice(item.lastIndexOf('/') + 1);
      if (/^[a-z0-9][a-z0-9+_.-]*$/.test(name) && !manifest.commands.some((command: NativeCommand) => command.name === name)) {
        writeSoLauncher(this.root + '/bin/' + name, libraries + 'libtoybox.so', 'bsh_toybox_main', 2);
      }
    }
    this.engineVersion = manifest.engineVersion; this.ready = true;
    this.installHarmonyPlugin();
    this.installTerminalPlugin();
    // 插件启用状态跨更新保持：显式 true 注册，显式 false 移除；没有显式值时不
    // 擅自改动已有行——旧版本默认装载过的插件（auto-review）说明用户此前就在用，
    // 升级不能替用户关掉。选择会写回 harmony-native.json，后续更新按它执行。
    const autoReview = this.readAutoReviewChoice();
    if (autoReview === true) {
      this.installAutoReviewPlugin();
    } else if (autoReview === false) {
      this.uninstallAutoReviewPlugin();
    } else {
      this.adoptAutoReviewPlugin();
    }
    this.installNotices();
    this.migrateLegacyHomePaths();
    // 新版运行时已经就绪，旧版本目录没有保留价值（一个版本约 450 MB）。
    // 放在成功之后做：本次解包失败时不动旧的，用户还能降级回上一个包。
    this.pruneOldRuntimes();
  }
  // 读取 .installed：新格式是 JSON（版本号 + 每文件 sha256 + 清单摘要）；
  // 旧格式只有版本号，返回 undefined 让调用方按未安装处理。
  private readInstalled(): InstalledRecord | undefined {
    try {
      const path = this.root + '/.installed';
      if (!fs.accessSync(path)) { return undefined; }
      const text = fs.readTextSync(path).trim();
      if (text.length === 0 || text.charAt(0) !== '{') { return undefined; }
      const record = JSON.parse(text) as InstalledRecord;
      if (record === null || typeof record.version !== 'string') { return undefined; }
      return record;
    } catch (error) { return undefined; }
  }
  // 抽查 INTEGRITY_FILES 的哈希并核对清单自身的摘要。任何缺失/不可读/不一致
  // 都返回 false，由 ensure() 走整棵重解；这里不删除 harness-home。
  private async verifyInstalled(record: InstalledRecord): Promise<boolean> {
    try {
      if (record.schema !== INSTALLED_SCHEMA || record.files === undefined ||
        typeof record.manifestSha256 !== 'string') { return false; }
      for (const relative of INTEGRITY_FILES) {
        const expected = record.files[relative];
        if (typeof expected !== 'string' || expected.length === 0) { return false; }
        const actual = await hash.hash(this.root + '/' + relative, 'sha256');
        if (actual.toLowerCase() !== expected) { return false; }
      }
      const raw = this.context.resourceManager.getRawFileContentSync('tools/runtime-manifest.json');
      return this.sha256Bytes(raw) === record.manifestSha256;
    } catch (error) { return false; }
  }
  // 安装成功后按实际落盘字节生成完整性清单。清单只覆盖关键文件（见
  // INTEGRITY_FILES 的取舍说明）；未列入的文件仍由整包重解恢复。
  private async writeInstalled(manifest: RuntimeManifest): Promise<void> {
    const files: Record<string, string> = {};
    for (const relative of INTEGRITY_FILES) {
      files[relative] = (await hash.hash(this.root + '/' + relative, 'sha256')).toLowerCase();
    }
    const raw = this.context.resourceManager.getRawFileContentSync('tools/runtime-manifest.json');
    const record: InstalledRecord = {
      version: manifest.version, schema: INSTALLED_SCHEMA,
      manifestSha256: this.sha256Bytes(raw), files: files
    };
    if (writeTxtFile(this.root + '/.installed', JSON.stringify(record) + '\n') !== 0) {
      throw new Error('运行时安装标记写入失败');
    }
  }
  // 对小块的 rawfile 字节算 sha256（用于清单自校验）；大文件走 file.hash。
  private sha256Bytes(bytes: Uint8Array): string {
    const digest = hash.createHash('sha256');
    const buffer = new ArrayBuffer(bytes.length);
    new Uint8Array(buffer).set(bytes);
    digest.update(buffer);
    return digest.digest().toLowerCase();
  }
  // 终端默认落在用户的工作区（DSH 的 home 工作区）而不是沙箱根目录。
  workspaceDirectory(): string {
    const home = this.context.filesDir + '/home';
    try { if (fs.accessSync(home)) { return home; } } catch (error) { /* 未创建 */ }
    return this.context.filesDir;
  }
  private nativeLibraryDirectory(): string {
    // The package manager selects the ABI; the emulator installs x86_64 while
    // physical devices normally install arm64. Older systems may omit this field.
    const reported = this.context.applicationInfo.nativeLibraryPath;
    const candidates: string[] = [];
    if (reported) { candidates.push(reported.endsWith('/') ? reported : reported + '/'); }
    candidates.push('/data/storage/el1/bundle/libs/arm64/', '/data/storage/el1/bundle/libs/x86_64/');
    for (const candidate of candidates) {
      try { if (fs.accessSync(candidate + 'libnode.so')) { return candidate; } } catch (error) { /* Try the next ABI path. */ }
    }
    throw new Error('未找到当前设备架构的原生运行时库');
  }
  // 旧运行时目录里有两万多个文件，一次性递归删除会把 UI 线程卡住超过 6 秒，
  // 触发 THREAD_BLOCK_6S 看门狗（首个升级到新运行时的版本就这样被系统杀掉，
  // 下次启动还会被当成「插件导致启动失败」进安全模式）。这里改成切片删除：
  // 每个宏任务最多删 8ms，剩下的用 setTimeout 让出去，界面保持可响应。
  private pruneQueue: string[] = [];
  private pruneTimer: number = -1;
  private pruneOldRuntimes(): void {
    const base = this.context.filesDir;
    const current = this.root.slice(base.length + 1);
    try {
      for (const name of fs.listFileSync(base)) {
        if (name === current || name.indexOf('runtime-') !== 0) { continue; }
        this.pruneQueue.push(base + '/' + name);
      }
    } catch (error) { /* 清理失败不影响运行 */ }
    this.pruneSlice();
  }
  private pruneSlice(): void {
    if (this.pruneQueue.length === 0) { return; }
    const deadline = Date.now() + 8;
    while (this.pruneQueue.length > 0 && Date.now() < deadline) {
      const path = this.pruneQueue.pop() as string;
      if (path.endsWith(PRUNE_REVISIT)) {
        // 子项已经处理完：空目录才删得掉；失败就放弃这一支，避免反复重试。
        try { fs.rmdirSync(path.slice(0, -1)); } catch (error) { /* 非空/已删 */ }
        continue;
      }
      try {
        const stat = fs.lstatSync(path);
        if (!stat.isDirectory()) {
          fs.unlinkSync(path);
          continue;
        }
        const children = fs.listFileSync(path);
        if (children.length === 0) {
          fs.rmdirSync(path);
          continue;
        }
        this.pruneQueue.push(path + PRUNE_REVISIT);
        for (const name of children) { this.pruneQueue.push(path + '/' + name); }
      } catch (error) { /* 已不存在或没权限：跳过 */ }
    }
    if (this.pruneQueue.length > 0) {
      this.pruneTimer = setTimeout(() => { this.pruneTimer = -1; this.pruneSlice(); }, 16);
    }
  }
  // fs.mkdirSync 在目录已存在时会抛 13900015（File exists），即使 recursion=true，
  // 所以这里先探测再创建：重试一次 ensure() 不能因为上次留下的空目录而失败。
  private ensureDir(path: string): void {
    if (!fs.accessSync(path)) { fs.mkdirSync(path, true); }
  }
  // rmdirSync 不递归（目录非空会抛 13900032），这里自己逐层删除。
  private removeTree(path: string): void {
    if (!fs.accessSync(path)) { return; }
    if (!fs.lstatSync(path).isDirectory()) { fs.unlinkSync(path); return; }
    for (const name of fs.listFileSync(path)) { this.removeTree(path + '/' + name); }
    fs.rmdirSync(path);
  }
  // ArkTS 只允许对象字面量对应已声明的接口或类，因此环境变量在这里整体构造。
  private buildEnv(): Record<string, string> {
    // HOME/TMPDIR 放在运行时目录外面：运行时目录换摘要后会整棵删除，
    // 而引擎（尤其是侧栏终端）会把工作目录持久化到会话里，一旦指向被删的
    // runtime-*/home，下次就报 "working-directory: directory does not exist"。
    const stableHome = this.context.filesDir + '/home';
    const stableTmp = this.context.filesDir + '/tmp';
    // 优先用合并后的 bundle（Mozilla 根证书 + 随包附加 CA）；合并失败时退回原 bundle。
    let caFile = this.root + '/certs/cacert.pem';
    try { if (fs.accessSync(this.root + '/certs/bundle.pem')) { caFile = this.root + '/certs/bundle.pem'; } } catch (error) { /* 保持回退 */ }
    const env: Record<string, string> = {
      'PATH': this.root + '/bin',
      'HOME': stableHome,
      'TMPDIR': stableTmp,
      'SHELL': this.root + '/bin/bash',
      'TERM': 'dumb',
      'LANG': 'C.UTF-8',
      'LC_ALL': 'C.UTF-8',
      'IEC_SYSROOT': this.root,
      'IEC_NODE_JITLESS': 'on',
      'NODE_EXTRA_CA_CERTS': caFile,
      'SSL_CERT_FILE': caFile,
      'GIT_SSL_CAINFO': caFile,
      // git 的 remote helper 与内建子命令都从 <sysroot>/bin 的启动器找；
      // 不设这个变量时会去 /usr/libexec/git-core（假根里没有），HTTPS 会失败。
      'GIT_EXEC_PATH': this.root + '/bin',
      // `git init` 的模板目录；空目录即可，见 ensure() 里的说明。
      'GIT_TEMPLATE_DIR': this.root + '/git-templates',
      'CURL_CA_BUNDLE': caFile,
      // libcrypto 的 OPENSSLDIR 是 /etc/ssl（构建机路径不能进设备二进制），默认配置
      // 在沙箱里不存在；`openssl req`/`ca` 找不到配置会直接失败，所以指到随运行时
      // 落盘的 <sysroot>/certs/openssl.cnf。
      'OPENSSL_CONF': this.root + '/certs/openssl.cnf',
      'PYTHONHOME': this.root + '/python',
      'PIP_CACHE_DIR': stableHome + '/.cache/pip',
      'VIMRUNTIME': this.root + '/vim/runtime',
      'PAGER': 'less',
      'GIT_PAGER': 'less',
      'EDITOR': 'vi',
      'VISUAL': 'vi',
      'GIT_EDITOR': 'vi',
      // Go's c-shared runtime and the C tools resolve the shell through PATH.
      'GIT_SSH_COMMAND': this.root + '/bin/ssh',
      'DSH_HOME': this.context.filesDir + '/harness-home',
      'DSH_PRIMARY_RUNTIME': '',
      'DSH_TELEMETRY_DISABLED': '1',
      // Node 在鸿蒙上跑在 --jitless 下，没有 WebAssembly；undici 的 fetch 需要它。
      // 预加载纯 JS 补丁，宿主与终端里的 node 都会用上。
      'NODE_OPTIONS': '--require ' + this.root + '/harmony/runtime-preload.cjs' +
        ' --require ' + this.root + '/harmony/fetch-polyfill.cjs'
    };

    return env;
  }
  // 鸿蒙适配插件的开关镜像文件（Host 插件写，应用读）。缺省视为关闭：
  // 后台保活要用户在设置里主动打开，才不会一装好就申请定位权限。
  readKeepAlive(): boolean {
    try {
      const file = this.context.filesDir + '/harness-home/harmony-native.json';
      if (!fs.accessSync(file)) { return false; }
      const text = fs.readTextSync(file);
      const parsed = JSON.parse(text) as Record<string, boolean>;
      return parsed.keepAlive === true;
    } catch (error) { return false; }
  }
  // 是否显示系统状态栏/导航栏（设置 → 通用 → 鸿蒙适配）。缺省 false：
  // 保持原来的沉浸式全屏，页面自己给挖孔与底部手势条让位。
  readShowSystemBars(): boolean {
    try {
      const file = this.context.filesDir + '/harness-home/harmony-native.json';
      if (!fs.accessSync(file)) { return false; }
      const text = fs.readTextSync(file);
      const parsed = JSON.parse(text) as Record<string, boolean>;
      return parsed.showSystemBars === true;
    } catch (error) { return false; }
  }
  // L-03：auto-review 是实验性“自动批准”预设（danger-full-access + LLM 裁决），
  // 默认不注册。需要恢复使用过 auto 预设的旧会话时，在
  // <filesDir>/harness-home/harmony-native.json 里写 {"autoReview": true} 再重启应用。
  // 返回 undefined 表示用户从未做过显式选择（旧版本遗留状态）。
  readAutoReviewChoice(): boolean | undefined {
    try {
      const file = this.context.filesDir + '/harness-home/harmony-native.json';
      if (!fs.accessSync(file)) { return undefined; }
      const text = fs.readTextSync(file);
      const parsed = JSON.parse(text) as Record<string, Object>;
      const value = parsed['autoReview'];
      if (value === true) { return true; }
      if (value === false) { return false; }
      return undefined;
    } catch (error) { return undefined; }
  }
  // 只写给应用壳层读的开关，保留 harmony-native.json 里的其它字段（keepAlive、
  // showSystemBars 等由 harmony-compat 插件负责）。原子替换，写一半不会损坏文件。
  private writeHarmonyNativeFlag(key: string, value: boolean): void {
    const dir = this.context.filesDir + '/harness-home';
    const file = dir + '/harmony-native.json';
    let current: Record<string, Object> = {};
    try {
      if (fs.accessSync(file)) {
        const parsed = JSON.parse(fs.readTextSync(file)) as Record<string, Object>;
        if (parsed !== null && typeof parsed === 'object') { current = parsed; }
      }
    } catch (error) { current = {}; }
    current[key] = value;
    this.ensureDir(dir);
    const temporary = file + '.tmp';
    const out = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(out.fd, JSON.stringify(current) + '\n');
    } finally {
      fs.closeSync(out);
    }
    fs.renameSync(temporary, file);
  }
  // 旧版本曾默认把 auto-review 插入行写进 profile。用户没有显式选择时，磁盘上
  // 已有这行就说明用户此前在用它：认可为开启并固化到 harmony-native.json，
  // 而不是按“默认关闭”把它删掉。其它由壳层托管的插件行同样只补缺、不删用户状态。
  private adoptAutoReviewPlugin(): void {
    const name = '@deepseek-ai/dsh-experimental-auto-review';
    const profileDir = this.context.filesDir + '/harness-home/profiles/web';
    const patchPath = profileDir + '/cordis.patch.yml';
    try {
      if (!fs.accessSync(patchPath)) { return; }
      const text = this.normalizeProfilePatch(fs.readTextSync(patchPath));
      if (text.indexOf(name) < 0) { return; }
      this.writeHarmonyNativeFlag('autoReview', true);
      this.installAutoReviewPlugin();
    } catch (error) { /* 读不到/写不进就维持现状，绝不主动关闭 */ }
  }
  // 一次性迁移：旧版本把 HOME 放在 runtime-<版本>/home，升级后该目录被删，
  // 会话里存的工作目录就失效。把 harness-home 里残留的这种路径改写成稳定路径。
  migrateLegacyHomePaths(): void {
    const base = this.context.filesDir + '/harness-home';
    const marker = this.context.filesDir + '/.harmony-home-migrated';
    try {
      if (fs.accessSync(marker) || !fs.accessSync(base)) { return; }
      const home = this.context.filesDir + '/home';
      const walk = (dir: string): void => {
        for (const name of fs.listFileSync(dir)) {
          const path = dir + '/' + name;
          const stat = fs.lstatSync(path);
          if (stat.isDirectory()) { walk(path); continue; }
          if (name === '.credentials.yaml' || !/\.(json|jsonl|yml|yaml)$/.test(name)) { continue; }
          let text = '';
          try { text = fs.readTextSync(path); } catch (error) { continue; }
          if (text.indexOf('/runtime-') < 0) { continue; }
          const replaced = text.replace(/\/runtime-[A-Za-z0-9.\-]+\/home/g, home);
          if (replaced !== text) {
            try { const file = fs.openSync(path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC); fs.writeSync(file.fd, replaced); fs.closeSync(file); } catch (error) { /* 单个文件失败不影响其它 */ }
          }
        }
      };
      walk(base);
      const markerFile = fs.openSync(marker, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(markerFile.fd, 'v1');
      fs.closeSync(markerFile);
    } catch (error) { /* 迁移失败不影响启动 */ }
  }
  private capture(command: string, args: string[]): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      let text = '';
      let timer: number = -1;
      const process = new NativeProcess(this.root + '/bin/' + command, args, this.root, this.env,
        (part: string) => { text += part; }, (code: number, error: string) => {
          if (timer >= 0) { clearTimeout(timer); }
          if (code === 0) { resolve(text); } else { reject(new Error(error || '原生命令探测失败')); }
        });
      timer = setTimeout(() => { process.close(); reject(new Error('原生命令探测超时')); }, 15000);
    });
  }
  // 官方 Web 界面：设备内起的就是 `dsh --profile web`，界面原样加载它打印的
  // http://127.0.0.1:<port>。端口用 0 让内核挑，避免和别的进程抢固定端口。
  async startWebUI(onLog: (text: string) => void,
    onInstalling?: (active: boolean) => void): Promise<string> {
    await this.ensure(onInstalling);
    if (this.webUrl) { return this.webUrl; }
    const env: Record<string, string> = this.buildEnv();
    return new Promise<string>((resolve, reject) => {
      let seen = '';
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) { return; }
        settled = true; this.web?.close(); this.web = undefined;
        reject(new Error('官方 Web 服务 180 秒内没有就绪：' + seen.slice(-600)));
      }, 180000);
      const binary = this.root + '/engine/node_modules/@deepseek-ai/dsh/lib/bin.js';
      // 鸿蒙适配插件以 profile bundle 的形式登记（见 installHarmonyPlugin），
      // 不再用 --patch：通过 --patch 插入的行在设置表单里是只读的，开关点不动。
      const args: string[] = [binary, '--profile', 'web', '--port', '0', '--no-open'];
      this.web = new NativeProcess(this.root + '/bin/node',
        args, this.context.filesDir, env,
        (text: string) => {
          this.appendLog('dsh.log', text);
          seen = (seen + text).slice(-16000);
          onLog(text);
          // 官方打印形如 "dsh web: http://127.0.0.1:53877/?token=..."，token 是
          // 打开界面的唯一凭据，必须整条交给 Web 组件；服务端会用它换 cookie 再
          // 重定向到干净的 ./。
          const match = /dsh web: (\S+)/.exec(seen);
          if (match && !settled) {
            settled = true; clearTimeout(timer);
            this.webUrl = match[1];
            resolve(this.webUrl);
          }
        },
        (code: number, error: string) => {
          if (settled) { return; }
          settled = true; clearTimeout(timer);
          // 引擎的 stderr 可能有几百行，界面只放得下开头几行；完整内容落到文件里，
          // 真机排查时用 hdc 直接取（files/logs/web-error.log）。
          this.writeLog('web-error.log', 'exit=' + code.toString() + '\n' + error + '\n\n--- stdout ---\n' + seen);
          reject(new Error('官方 Web 服务已退出（' + code.toString() + '）：' + error.slice(0, 1200)));
        }, (text: string) => { this.appendLog('web-stderr.log', text); });
    });
  }
  stopWebUI(): void { this.web?.close(); this.web = undefined; this.webUrl = ''; }
  // 鸿蒙适配插件：引擎归档里带一份；profile 层的行只从 profile 自己的
  // node_modules 解析，所以启动时同步包目录，并把它的插入行写进 profile 的
  // 用户 patch 层（cordis.patch.yml）。这样它是「用户可编辑」的行，设置表单可写。
  private installHarmonyPlugin(): void {
    const name = '@deepseek-ai/dsh-harmony-compat';
    const source = this.root + '/engine/node_modules/' + name;
    const profileDir = this.context.filesDir + '/harness-home/profiles/web';
    const dest = profileDir + '/node_modules/' + name;
    try {
      if (!fs.accessSync(source)) { return; }
      this.removeTree(dest);
      this.ensureDir(dest);
      this.copyTree(source, dest);

      const manifestPath = profileDir + '/package.json';
      if (fs.accessSync(manifestPath)) {
        const manifest = JSON.parse(fs.readTextSync(manifestPath)) as Record<string, Object>;
        const dsh = manifest['dsh'] as Record<string, Object> | undefined;
        const profile = dsh ? dsh['profile'] as Record<string, Object> | undefined : undefined;
        if (profile) {
          const bundles = (profile['bundles'] as string[]) ?? [];
          const filtered = bundles.filter((item: string) => item !== name);
          if (filtered.length !== bundles.length) {
            profile['bundles'] = filtered;
            const file = fs.openSync(manifestPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
            fs.writeSync(file.fd, JSON.stringify(manifest, null, 2) + '\n');
            fs.closeSync(file);
          }
        }
      }

      const patchPath = profileDir + '/cordis.patch.yml';
      const row = "- insert:\n    - id: harmony-native\n      name: '" + name + "'\n";
      this.appendProfilePatchRow(patchPath, name, row);
    } catch (error) { /* 同步失败只是插件不出现，不影响引擎 */ }
  }
  // profile 的 cordis.patch.yml 初始内容是一段注释加空数组「[]」。直接在「[]」后面
  // 追加 patch 行会让整份 YAML 解析失败（引擎起不来），追加前必须把这行去掉。
  private normalizeProfilePatch(text: string): string {
    const kept: string[] = [];
    for (const line of text.split('\n')) {
      if (line.trim() === '[]') { continue; }
      kept.push(line);
    }
    return kept.join('\n');
  }
  private appendProfilePatchRow(patchPath: string, marker: string, row: string): void {
    let text = fs.accessSync(patchPath) ? this.normalizeProfilePatch(fs.readTextSync(patchPath)) : '';
    if (text.indexOf(marker) >= 0) { return; }
    if (text.length > 0 && !text.endsWith('\n')) { text += '\n'; }
    text += row;
    const file = fs.openSync(patchPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, text);
    fs.closeSync(file);
  }
  // 只有 harmony-native.json 的 autoReview=true 才会走到这里（见 ensure()）。
  // 旧会话的权限预设可能记成 "auto"。这个预设由 dsh-experimental-auto-review 提供
  // （registerAuto）；web profile 默认不加载它，恢复会话时会报
  // permission: cannot restore preset "auto" without its active integration，
  // 会话随即从侧栏消失、重启才回来。显式开启后把插入行补进 profile 即可。
  private installAutoReviewPlugin(): void {
    const name = '@deepseek-ai/dsh-experimental-auto-review';
    const source = this.root + '/engine/node_modules/' + name + '/package.json';
    const profileDir = this.context.filesDir + '/harness-home/profiles/web';
    try {
      if (!fs.accessSync(source)) { return; }
      this.appendProfilePatchRow(profileDir + '/cordis.patch.yml', name,
        "- insert:\n    - id: auto-review\n      name: '" + name + "'\n");
    } catch (error) { /* 缺失只影响记了 auto 预设的旧会话恢复 */ }
  }
  // 开关关闭时移除旧版本（或无开关版本）自动写进 profile 的 auto-review 行。
  // 不删的话覆盖升级后旧行仍在，默认关闭就只是“不再新增”，没有真正生效。
  private uninstallAutoReviewPlugin(): void {
    const name = '@deepseek-ai/dsh-experimental-auto-review';
    const profileDir = this.context.filesDir + '/harness-home/profiles/web';
    const patchPath = profileDir + '/cordis.patch.yml';
    try {
      if (!fs.accessSync(patchPath)) { return; }
      const text = this.normalizeProfilePatch(fs.readTextSync(patchPath));
      const row = "- insert:\n    - id: auto-review\n      name: '" + name + "'\n";
      if (text.indexOf(row) < 0) { return; }
      let next = text.split(row).join('');
      if (next.trim().length === 0) { next = '[]\n'; }
      const file = fs.openSync(patchPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, next);
      fs.closeSync(file);
    } catch (error) { /* 清理失败只意味着旧插入行仍在 */ }
  }
  // 原生终端插件：随 HAP 以 rawfile 分发，启动时同步进 profile 的 node_modules，
  // 并往 cordis.patch.yml 写一行插入。它只在浏览器侧注册右侧栏的终端 tab，
  // 画面和会话都归壳层（见 plugins/dsh-harmony-terminal）。
  private installTerminalPlugin(): void {
    const name = '@local/dsh-harmony-terminal';
    const profileDir = this.context.filesDir + '/harness-home/profiles/web';
    const dest = profileDir + '/node_modules/@local/dsh-harmony-terminal';
    const files: string[] = ['package.json', 'index.js', 'client.js', 'cordis.patch.yml'];
    try {
      this.removeTree(dest);
      this.ensureDir(profileDir + '/node_modules/@local');
      this.ensureDir(dest);
      const decoder = util.TextDecoder.create('utf-8');
      for (const file of files) {
        const content = this.context.resourceManager.getRawFileContentSync('tools/harmony-terminal/' + file);
        const text = decoder.decodeToString(content);
        const out = fs.openSync(dest + '/' + file, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        fs.writeSync(out.fd, text);
        fs.closeSync(out);
      }

      const patchPath = profileDir + '/cordis.patch.yml';
      const row = "- insert:\n    - id: harmony-native-terminal\n      name: '" + name + "'\n";
      // 自带的终端 tab 换成原生终端：上游那条只提供 Web 终端界面，它的 PTY 在
      // 鸿蒙沙箱里起不来。行 id 取自 web-app bundle 的 cordis.patch.yml
      // （ui-sidebar-terminal），按 package 名写是匹配不到的。
      const upstreamName = '@deepseek-ai/dsh-client-ui-sidebar-terminal';
      const upstream = "- id: 'ui-sidebar-terminal'\n  disabled: true\n";
      const stale = "- id: '" + upstreamName + "'\n  disabled: true\n";
      let text = fs.accessSync(patchPath) ? this.normalizeProfilePatch(fs.readTextSync(patchPath)) : '';
      if (text.indexOf(stale) >= 0) { text = text.split(stale).join(''); }
      let changed = false;
      if (text.indexOf(name) < 0) {
        if (text.length > 0 && !text.endsWith('\n')) { text += '\n'; }
        text += row;
        changed = true;
      }
      if (text.indexOf(upstream) < 0) {
        if (text.length > 0 && !text.endsWith('\n')) { text += '\n'; }
        text += upstream;
        changed = true;
      }
      if (changed) {
        const file = fs.openSync(patchPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        fs.writeSync(file.fd, text);
        fs.closeSync(file);
      }
    } catch (error) { /* 插件没装上只是没有侧栏终端入口 */ }
  }
  // 第三方声明随 HAP 以 rawfile 分发，启动时解到应用沙箱，方便用户/审计直接查看，
  // 也保证分发物里始终带着 MIT / GPL / BSD 等许可证原文。
  private installNotices(): void {
    const dest = this.context.filesDir + '/notices';
    const files: string[] = [
      'THIRD_PARTY_NOTICES.md',
      'LICENSES/Apache-2.0-LLVM.txt', 'LICENSES/Artistic-2.0.txt', 'LICENSES/DSH-MIT.txt',
      'LICENSES/GPL-2.0.txt', 'LICENSES/GPL-3.0.txt', 'LICENSES/libarchive.txt',
      'LICENSES/libvterm.txt', 'LICENSES/Node-MIT.txt', 'LICENSES/ripgrep-MIT.txt',
      'LICENSES/ripgrep-UNLICENSE.txt', 'LICENSES/toybox.txt',
      'LICENSES/Apache-2.0-OpenSSL.txt', 'LICENSES/curl.txt', 'LICENSES/pcre2.txt',
      'LICENSES/zlib.txt', 'LICENSES/bzip2.txt'
    ];
    try {
      this.ensureDir(dest);
      this.ensureDir(dest + '/LICENSES');
      const decoder = util.TextDecoder.create('utf-8');
      for (const file of files) {
        const content = this.context.resourceManager.getRawFileContentSync('notices/' + file);
        const text = decoder.decodeToString(content);
        const out = fs.openSync(dest + '/' + file, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        fs.writeSync(out.fd, text);
        fs.closeSync(out);
      }
    } catch (error) { /* 声明文件缺失不影响运行 */ }
  }
  // 鸿蒙上 Node 以 --jitless 运行，WebAssembly 被关掉，内置 undici 的 fetch
  // 因此不可用。把纯 JS 的 fetch 补丁写进运行时，并用 NODE_OPTIONS 预加载。
  // TLS 信任的是「Mozilla 根证书 + 可选附加 CA」合并后的 bundle，不做任何
  // 运行时放宽。附加 CA（rawfile/harmony/extra-ca.pem）只给会拦截 HTTPS 的
  // 开发环境使用，默认不随仓库分发；公开/商店构建保持缺省或换企业根证书。
  private installTrustBundle(): void {
    const dir = this.root + '/certs';
    try {
      let text = fs.readTextSync(dir + '/cacert.pem');
      try {
        const extra = this.context.resourceManager.getRawFileContentSync('harmony/extra-ca.pem');
        const extraText = util.TextDecoder.create('utf-8').decodeToString(extra);
        if (extraText.indexOf('BEGIN CERTIFICATE') >= 0) {
          const copy = fs.openSync(dir + '/extra-ca.pem', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
          fs.writeSync(copy.fd, extraText);
          fs.closeSync(copy);
          if (!text.endsWith('\n')) { text += '\n'; }
          text += extraText;
        }
      } catch (error) { /* 没有随包附加 CA 时只用 Mozilla 根证书 */ }
      const out = fs.openSync(dir + '/bundle.pem', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(out.fd, text);
      fs.closeSync(out);
    } catch (error) { /* 合并失败时 buildEnv 会回退到 cacert.pem */ }
  }
  // OpenSSL：libcrypto 里编进去的 OPENSSLDIR 是 /etc/ssl（构建机路径不能进设备），
  // 沙箱里没有那个目录，`openssl req`/`ca` 会因为找不到 openssl.cnf 直接失败。
  // 这里把随包的配置写到 <sysroot>/certs/openssl.cnf，buildEnv() 用 OPENSSL_CONF
  // 指过去；同时建好 `openssl ca` 需要的目录与索引文件。
  private installOpensslConfig(): void {
    const dir = this.root + '/certs';
    try {
      this.ensureDir(dir);
      const content = this.context.resourceManager.getRawFileContentSync('harmony/openssl.cnf');
      const text = util.TextDecoder.create('utf-8').decodeToString(content);
      const out = fs.openSync(dir + '/openssl.cnf', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(out.fd, text);
      fs.closeSync(out);
      const ca = dir + '/ca';
      this.ensureDir(ca);
      this.ensureDir(ca + '/certs');
      this.ensureDir(ca + '/newcerts');
      this.ensureDir(ca + '/private');
      if (!fs.accessSync(ca + '/index.txt')) { writeTxtFile(ca + '/index.txt', ''); }
      if (!fs.accessSync(ca + '/serial')) { writeTxtFile(ca + '/serial', '1000\n'); }
    } catch (error) { /* 配置缺失只影响 req/ca；其它 openssl 子命令仍可用 */ }
  }
  // DSH 会把 $DSH_HOME/AGENTS.md 当作用户级全局指令读进每个会话。这里写入的是
  // 应用内置说明：每次启动重写，避免用户/Agent 的改动被当成持久规则；
  // 用户自己的规则应写到工作区的 AGENTS.md（优先级更高）。
  private installBuiltinAgents(): void {
    const target = this.context.filesDir + '/harness-home/AGENTS.md';
    const code = installRawfileFile('agents/AGENTS.md', target);
    if (code !== 0) {
      console.warn('[agents] 内置 AGENTS.md 写入失败：' + code.toString());
    }
  }
  private installFetchPolyfill(): void {
    const dir = this.root + '/harmony';
    try {
      this.ensureDir(dir);
      const content = this.context.resourceManager.getRawFileContentSync('harmony/fetch-polyfill.cjs');
      const text = util.TextDecoder.create('utf-8').decodeToString(content);
      const out = fs.openSync(dir + '/fetch-polyfill.cjs', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(out.fd, text);
      fs.closeSync(out);
    } catch (error) { /* 补丁缺失时退回原生 fetch（有 WASM 的设备不受影响） */ }
  }
  // 鸿蒙上 process.report.getReport() 的 CPU 枚举会阻塞事件循环约 30 秒；
  // 原生插件加载器只用它判断 musl/glibc，这里提前短路成最小报告。
  private installRuntimePreload(): void {
    const dir = this.root + '/harmony';
    try {
      this.ensureDir(dir);
      const content = this.context.resourceManager.getRawFileContentSync('harmony/runtime-preload.cjs');
      const text = util.TextDecoder.create('utf-8').decodeToString(content);
      const out = fs.openSync(dir + '/runtime-preload.cjs', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(out.fd, text);
      fs.closeSync(out);
    } catch (error) { /* 补丁缺失时退回原始 process.report 行为 */ }
  }
  private copyTree(from: string, to: string): void {
    for (const name of fs.listFileSync(from)) {
      const src = from + '/' + name;
      const dst = to + '/' + name;
      if (fs.lstatSync(src).isDirectory()) { this.ensureDir(dst); this.copyTree(src, dst); continue; }
      fs.copyFileSync(src, dst);
    }
  }
  // 运行时目录被改坏时的整棵重建：停掉子进程、删掉这棵目录、把状态归零，
  // 然后重新走 ensure()（它会重新解包并写 .installed）。
  async repair(onInstalling?: (active: boolean) => void): Promise<void> {
    this.stopWebUI();
    if (this.root) {
      // 删除旧运行时同样要遍历整棵目录树，先让界面切到「正在解包」再动手。
      if (onInstalling !== undefined) {
        onInstalling(true);
        await pause(300);
      }
      this.removeTree(this.root);
    }
    this.ready = false;
    this.root = '';
    this.env = {};
    await this.ensure();
    if (onInstalling !== undefined) { onInstalling(false); }
  }
  // 引擎的 stdout/stderr 追加写文件，排查终端/API 报错时能直接看。
  // 落盘前统一脱敏（redactLogText），并按累计字节轮转，避免凭据入盘/磁盘无限增长。
  private appendLog(name: string, text: string): void {
    try {
      const dir = this.context.filesDir + '/logs';
      if (!fs.accessSync(dir)) { fs.mkdirSync(dir, true); }
      const path = dir + '/' + name;
      const safe = redactLogText(text);
      const bytes = this.logEncoder.encodeInto(safe).length;
      let size = this.logBytes[name];
      if (size === undefined) {
        size = 0;
        try { if (fs.accessSync(path)) { size = fs.statSync(path).size; } } catch (error) { /* 按空文件累计 */ }
      }
      if (size > 0 && size + bytes > LOG_ROTATE_BYTES) {
        this.rotateLog(path);
        size = 0;
      }
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND);
      fs.writeSync(file.fd, safe);
      fs.closeSync(file);
      this.logBytes[name] = size + bytes;
    } catch (error) { /* 日志失败不影响运行 */ }
  }
  // 真机排查用：把引擎输出写到 files/logs 下，hdc shell 可以直接读。
  // 这里同样脱敏：dsh.log 会带 token，诊断用的 web-error.log 也不该留明文。
  private writeLog(name: string, text: string): void {
    try {
      const dir = this.context.filesDir + '/logs';
      if (!fs.accessSync(dir)) { fs.mkdirSync(dir, true); }
      const file = fs.openSync(dir + '/' + name, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, redactLogText(text));
      fs.closeSync(file);
    } catch (error) { /* 日志写不进去不能影响主流程 */ }
  }
  // 启动时准备日志目录并检查上次遗留的 dsh.log：连续写入只在累计超限时轮转，
  // 启动这次 stat 用来把“上次已经很大”的文件先转走并给本进程一个准确基数。
  private prepareLogs(): void {
    try {
      const dir = this.context.filesDir + '/logs';
      if (!fs.accessSync(dir)) { fs.mkdirSync(dir, true); }
      for (const name of ['dsh.log', 'web-stderr.log']) {
        const path = dir + '/' + name;
        let size = 0;
        if (fs.accessSync(path)) { size = fs.statSync(path).size; }
        if (size > LOG_ROTATE_BYTES) {
          this.rotateLog(path);
          size = 0;
        }
        this.logBytes[name] = size;
      }
      this.pruneNativeLogs(dir);
    } catch (error) { /* 日志目录不可用时 appendLog 会再尝试 */ }
  }
  // 原生 logger 每次进程启动都会生成新的 iec-<pid>-<时间>.log（含 .1/.2 分片），
  // 进程退出后不再写入。只保留最近 10 个，避免 files/logs 长期累积。
  private pruneNativeLogs(dir: string): void {
    try {
      const entries: string[] = [];
      const times: Record<string, number> = {};
      let count = 0;
      for (const name of fs.listFileSync(dir)) {
        if (!/^iec-.*\.log(\.\d+)?$/.test(name)) { continue; }
        try {
          times[name] = fs.statSync(dir + '/' + name).mtime;
          entries.push(name);
          count += 1;
        } catch (error) { /* 单个文件不可读时跳过 */ }
      }
      if (count <= 10) { return; }
      entries.sort((left: string, right: string) => (times[right] ?? 0) - (times[left] ?? 0));
      for (let index = 10; index < entries.length; index++) {
        try { fs.unlinkSync(dir + '/' + entries[index]); } catch (error) { /* 删不掉就留着 */ }
      }
    } catch (error) { /* 列表失败不影响启动 */ }
  }
  // dsh.log -> dsh.log.1 -> dsh.log.2；超过 LOG_BACKUP_COUNT 的旧分片删除。
  private rotateLog(path: string): void {
    try {
      for (let index = LOG_BACKUP_COUNT - 1; index >= 1; index--) {
        const from = path + '.' + index.toString();
        const to = path + '.' + (index + 1).toString();
        if (!fs.accessSync(from)) { continue; }
        if (fs.accessSync(to)) { fs.unlinkSync(to); }
        fs.renameSync(from, to);
      }
      if (fs.accessSync(path + '.1')) { fs.unlinkSync(path + '.1'); }
      if (fs.accessSync(path)) { fs.renameSync(path, path + '.1'); }
    } catch (error) { /* 轮转失败时保持原文件继续追加 */ }
  }
  async connect(key: string, settings: Settings, hooks: EngineHooks): Promise<OfficialRpc> {
    if (this.rpc) { return this.rpc; }
    await this.ensure();
    const env: Record<string, string> = this.buildEnv();
    env.DEEPSEEK_API_KEY = key; env.DEEPSEEK_BASE_URL = settings.endpoint;
    const process = new NativeProcess(this.root + '/bin/node', [this.root + '/engine/node_modules/@deepseek-ai/dsh/lib/bin.js', '--profile', 'sdk'],
      this.context.filesDir, env, (text: string) => { this.rpc?.receive(text); }, (code: number, error: string) => {
        const safe = error.split(key).join('[REDACTED]');
        this.rpc?.dispose('官方引擎已退出（' + code.toString() + '）：' + safe); this.rpc = undefined; this.owned.clear();
      });
    this.process = process; this.rpc = new OfficialRpc(process, hooks);
    try {
      const identity = await this.rpc.request('initialize', {
        cwd: this.context.filesDir, provider: 'deepseek-official', model: settings.model,
        reasoningEffort: settings.thinking ? 'high' : 'off', approvalRequests: true, capabilities: { userQuestions: true }
      }, 60000) as ServerIdentity;
      if (identity.serverInfo.name !== 'deepseek-harness-sdk-runtime') { throw new Error('官方引擎身份不匹配'); }
      return this.rpc;
    } catch (error) { this.stopEngine(); throw new Error((error as Error).message); }
  }
  async prepareSession(id: string, cwd: string, persisted: boolean): Promise<void> {
    if (!this.rpc) { throw new Error('官方引擎未连接'); }
    if (!this.owned.has(id)) {
      if (persisted) { await this.rpc.request('session/resume', { sessionId: id }); }
      await this.rpc.request('session/working-directory/set', { sessionId: id, path: cwd });
      this.owned.add(id);
    }
  }
  async ensureReady(): Promise<void> { await this.ensure(); }
  // 非交互命令：一次 bash -lc，输出按流回传。真正的 PTY 需要 node-pty，见文档的已知边界。
  runShell(command: string, cwd: string, output: (text: string) => void, exit: (code: number, error: string) => void): void {
    if (!this.ready) { exit(-1, '原生运行时未就绪'); return; }
    this.shell?.close();
    this.shell = new NativeProcess(this.root + '/bin/bash', ['-lc', command], cwd, this.env, output, exit);
  }
  stopShell(): void { this.shell?.close(); this.shell = undefined; }
  startTerminal(cwd: string, output: (text: string) => void, exit: (code: number, error: string) => void): void {
    this.terminal?.close();
    this.terminal = new NativeProcess(this.root + '/bin/node', [this.root + '/engine/harmony/terminal-host.cjs', cwd],
      cwd, this.env, output, exit);
  }
  terminalWrite(data: string): Promise<void> {
    if (!this.terminal) { return Promise.reject(new Error('终端未启动')); }
    const line = JSON.stringify({ type: 'input', data: data }).replace(/[\u007f-\uffff]/g,
      (ch: string) => '\\u' + ch.charCodeAt(0).toString(16).padStart(4, '0')) + '\n';
    return this.terminal.write(line);
  }
  stopTerminal(): void { this.terminal?.close(); this.terminal = undefined; }
  // 官方引擎只提供 shutdown：先请求退出，1.5 秒内没有结束就强制回收进程。
  stopEngine(): void {
    const rpc = this.rpc; const process = this.process;
    this.rpc = undefined; this.process = undefined; this.owned.clear();
    if (!rpc) { process?.close(); return; }
    rpc.shutdown();
    setTimeout(() => { process?.close(); }, 1500);
  }
}
