import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { execStart, execPoll, execWrite, execCloseStdin, execTerminate, execRelease,
  initIecResourceManager, installCaBundle, probeCaps, startIecServer, unpackResource, writeSoLauncher, writeTxtFile } from 'iec';
import { EngineHooks, EnginePipe, OfficialRpc } from '../core/OfficialRpc';
import { Settings } from '../core/Types';

interface NativeCommand { name: string; library: string; entry: string; arity?: number }
interface RuntimeManifest { version: string; engineVersion: string; nodeVersion: string; commands: NativeCommand[] }
interface ServerIdentity { serverInfo: ServerInfo }
interface ServerInfo { name: string; version: string }

function pause(ms: number): Promise<void> { return new Promise<void>((resolve) => { setTimeout(resolve, ms); }); }

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
  engineVersion: string = '';
  // 终端页复用同一个运行时实例：ensure() 已经做过 probeCaps/startIecServer，
  // 再 new 一个实例会在 UI 线程重复探测，造成输入阻塞。
  get rootDir(): string { return this.root; }
  get environment(): Record<string, string> { return this.env; }
  // 当前是否在整棵解包/重装运行时：启动页据此决定要不要提示「首次启动」。
  get isInstalling(): boolean { return this.installing; }
  constructor(context: common.UIAbilityContext) { this.context = context; }
  async ensure(): Promise<void> {
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
    this.ensureDir(this.context.filesDir + '/home');
    this.ensureDir(this.context.filesDir + '/tmp');
    // 启动时的检查只看「标记在不在 + 两棵关键子树在不在」，不做哈希：
    // 摘要只在打包时算一次（pack-native.sh），设备上不重复校验内容。
    // 加这两条存在性检查是为了半棵树（解包中断、沙箱被清了一部分）能自愈，
    // 否则 .installed 会让每次启动都跳过重解，直接卡在同一个错误上。
    const complete = fs.accessSync(this.root + '/.installed') &&
      fs.accessSync(this.root + '/engine/node_modules/@deepseek-ai/dsh/lib/bin.js') &&
      fs.accessSync(this.root + '/npm/bin/npm-cli.js');
    // 启动页据此决定是否提示「首次启动需要解包」，只有这里为 true 时才是真在解包。
    this.installing = !complete;
    if (!complete) {
      // 标记与解包结果对不上：整棵运行时重来，而不是只补 engine。
      this.removeTree(this.root);
      this.ensureDir(this.root);
      this.ensureDir(this.root + '/bin');
      this.ensureDir(this.root + '/home');
      this.ensureDir(this.root + '/tmp');
      this.ensureDir(this.root + '/engine');
      const engineCode = unpackResource('tools/official-engine.tar.gz', this.root + '/engine');
      if (engineCode !== 0) {
        this.removeTree(this.root + '/engine');
        throw new Error('官方引擎解包失败（unpackResource=' + engineCode.toString() + '）');
      }
      const npmCode = unpackResource('tools/npm.tar.gz', this.root);
      if (npmCode !== 0) { throw new Error('npm 解包失败（unpackResource=' + npmCode.toString() + '）'); }
      if (writeTxtFile(this.root + '/.installed', manifest.version) !== 0) { throw new Error('运行时安装标记写入失败'); }
    }
    this.installing = false;
    for (const command of manifest.commands) {
      // bash 的入口是 main(argc, argv, envp) 三参形状；按 2 参调用会把 envp 留成
      // 寄存器垃圾，bash 初始化变量时立刻崩溃。其余命令都是两参入口。
      const arity = command.arity === 3 ? 3 : 2;
      if (writeSoLauncher(this.root + '/bin/' + command.name, libraries + command.library, command.entry, arity) !== 0) {
        throw new Error('命令启动器写入失败：' + command.name);
      }
    }
    installCaBundle(this.root + '/certs');
    this.installFetchPolyfill();
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
    this.installNotices();
    this.migrateLegacyHomePaths();
    // 新版运行时已经就绪，旧版本目录没有保留价值（一个版本约 450 MB）。
    // 放在成功之后做：本次解包失败时不动旧的，用户还能降级回上一个包。
    this.pruneOldRuntimes();
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
  private pruneOldRuntimes(): void {
    const base = this.context.filesDir;
    const current = this.root.slice(base.length + 1);
    try {
      for (const name of fs.listFileSync(base)) {
        if (name === current || name.indexOf('runtime-') !== 0) { continue; }
        this.removeTree(base + '/' + name);
      }
    } catch (error) { /* 清理失败不影响运行 */ }
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
      'NODE_EXTRA_CA_CERTS': this.root + '/certs/cacert.pem',
      'SSL_CERT_FILE': this.root + '/certs/cacert.pem',
      'GIT_SSL_CAINFO': this.root + '/certs/cacert.pem',
      'CURL_CA_BUNDLE': this.root + '/certs/cacert.pem',
      'DSH_HOME': this.context.filesDir + '/harness-home',
      'DSH_PRIMARY_RUNTIME': '',
      'DSH_TELEMETRY_DISABLED': '1',
      // Node 在鸿蒙上跑在 --jitless 下，没有 WebAssembly；undici 的 fetch 需要它。
      // 预加载纯 JS 补丁，宿主与终端里的 node 都会用上。
      'NODE_OPTIONS': '--require ' + this.root + '/harmony/fetch-polyfill.cjs'
    };
    if (this.readInsecureTls()) {
      // 只信任抓到的中间人根证书（TOFU），不全局关闭校验；详见 fetch-polyfill.cjs。
      env['DSH_TRUST_INTERCEPTED_CA'] = '1';
      env['DSH_INTERCEPTED_CA_FILE'] = this.root + '/certs/intercepted-ca.pem';
      env['DSH_INTERCEPTED_CA_COPY'] = this.context.filesDir + '/local-ca.pem';
    }

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
  // 开发/模拟器环境的 TLS 逃生口：有些模拟器或抓包代理会做 HTTPS 中间人，
  // 系统浏览器（ArkWeb）信系统证书库所以正常，而 Node 只信随包的 Mozilla 根证书，
  // 于是登录请求报 SELF_SIGNED_CERT_IN_CHAIN。默认关闭；用户在
  // harness-home/harmony-native.json 里显式写 allowInsecureTls: true 才生效。
  readInsecureTls(): boolean {
    try {
      const file = this.context.filesDir + '/harness-home/harmony-native.json';
      if (!fs.accessSync(file)) { return false; }
      const parsed = JSON.parse(fs.readTextSync(file)) as Record<string, boolean>;
      return parsed.allowInsecureTls === true;
    } catch (error) { return false; }
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
  async startWebUI(onLog: (text: string) => void): Promise<string> {
    await this.ensure();
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
      let text = fs.accessSync(patchPath) ? fs.readTextSync(patchPath) : '';
      if (text.indexOf(name) < 0) {
        if (text.length > 0 && !text.endsWith('\n')) { text += '\n'; }
        text += row;
        const file = fs.openSync(patchPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        fs.writeSync(file.fd, text);
        fs.closeSync(file);
      }
    } catch (error) { /* 同步失败只是插件不出现，不影响引擎 */ }
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
      let text = fs.accessSync(patchPath) ? fs.readTextSync(patchPath) : '';
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
      'LICENSES/GPL-3.0.txt', 'LICENSES/libarchive.txt', 'LICENSES/libvterm.txt',
      'LICENSES/Node-MIT.txt', 'LICENSES/ripgrep-MIT.txt', 'LICENSES/ripgrep-UNLICENSE.txt',
      'LICENSES/toybox.txt'
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
  async repair(): Promise<void> {
    this.stopWebUI();
    if (this.root) { this.removeTree(this.root); }
    this.ready = false;
    this.root = '';
    this.env = {};
    await this.ensure();
  }
  // 引擎的 stdout/stderr 追加写文件，排查终端/API 报错时能直接看。
  private appendLog(name: string, text: string): void {
    try {
      const dir = this.context.filesDir + '/logs';
      if (!fs.accessSync(dir)) { fs.mkdirSync(dir, true); }
      const file = fs.openSync(dir + '/' + name, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND);
      fs.writeSync(file.fd, text);
      fs.closeSync(file);
    } catch (error) { /* 日志失败不影响运行 */ }
  }
  // 真机排查用：把引擎输出写到 files/logs 下，hdc shell 可以直接读。
  private writeLog(name: string, text: string): void {
    try {
      const dir = this.context.filesDir + '/logs';
      if (!fs.accessSync(dir)) { fs.mkdirSync(dir, true); }
      const file = fs.openSync(dir + '/' + name, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, text);
      fs.closeSync(file);
    } catch (error) { /* 日志写不进去不能影响主流程 */ }
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
