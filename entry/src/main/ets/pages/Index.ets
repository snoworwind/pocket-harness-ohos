import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { window, mediaquery } from '@kit.ArkUI';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { util, url } from '@kit.ArkTS';
import { TerminalView } from './Terminal';
import { BrowserControl, BrowserView } from './Browser';
import { BrowserConsentControl, BrowserConsentView } from './BrowserConsent';
import { BrowserBridge, BrowserBridgeApproval, BrowserBridgeHost } from '../platform/BrowserBridge';
import { BrowserRelayReady } from '../platform/BrowserRelay';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NativeRuntime } from '../platform/NativeRuntime';
import { BackgroundKeepAlive } from '../platform/BackgroundKeepAlive';
import { PluginGuard } from '../platform/PluginGuard';
import { IMMERSIVE_TOP_GAP, avoidAreaBottom, setSystemBarVisible } from '../platform/WindowMode';

// 页面里的终端入口把 location.hash 改成 #dshterm，原生轮询 controller.getUrl() 读取，
// 不依赖 javascriptProxy 注册，避免桥上偶发失效。

// 附件上传的默认通道是 blob: Worker（dsh-client-file-upload 的 workerTransport），
// ArkWeb 对「blob URL 建 Worker + 立刻 revokeObjectURL」这条链路不可靠，表现为
// 任何附件都停在上传失败。客户端 FileUploadRuntime 构造时会读 globalThis.__DSH_FILE_UPLOAD__，
// 存在就改用它的 fetch 钩子；这里在文档开始时注入，保证早于客户端 Cordis 启动。
// fetch 是同源请求，cookie 由内核自动携带；个别内核拒绝 Blob 请求体时退成 ArrayBuffer 重发一次。
const UPLOAD_DOCUMENT_SCRIPT: string =
  "(function(){try{" +
  "var post=function(input,init){" +
  "if(!init||typeof Blob!=='function'||!(init.body instanceof Blob)){return fetch(input,init);}" +
  "return fetch(input,init).catch(function(error){" +
  "if(init.signal&&init.signal.aborted){throw error;}" +
  "return init.body.arrayBuffer().then(function(buffer){" +
  "var retry={};for(var key in init){if(key!=='body'&&key!=='duplex'){retry[key]=init[key];}}" +
  "retry.body=buffer;return fetch(input,retry);});});};" +
  "window.__DSH_FILE_UPLOAD__={fetch:post};" +
  "}catch(e){}})();";

// ArkWeb 把自定义 scheme 当 opaque URL：new URL('dsh-resource://file/…').hostname
// 恒为空，而客户端 @deepseek-ai/dsh-client-resources 的 protocolOf() 正是用
// hostname 当协议键。于是资源记录一律被判成「没有 provider」，侧栏文件、聊天
// 文件链接、交付物预览统一显示「文件资源服务不可用」。这里在文档起点只给
// dsh-resource: 且原生 hostname 为空的 URL 补出 host；解析正常的引擎和其它
// scheme 保持原样（鸿蒙 ArkWeb 7.0.0.105 实测 hostname 为空）。
const RESOURCE_URL_DOCUMENT_SCRIPT: string =
  "(function(){try{" +
  "if(window.__dshResourceUrlShim){return;}window.__dshResourceUrlShim=true;" +
  "var U=window.URL;if(!U||!U.prototype){return;}" +
  "var desc=Object.getOwnPropertyDescriptor(U.prototype,'hostname');" +
  "if(!desc||typeof desc.get!=='function'){return;}" +
  "var nativeGet=desc.get;" +
  "var hostOf=function(href){" +
  "var m=/^dsh-resource:\\/\\/([^\\/?#]*)/i.exec(String(href||''));" +
  "if(!m){return '';}" +
  "var authority=m[1];var at=authority.lastIndexOf('@');if(at>=0){authority=authority.slice(at+1);}" +
  "var colon=authority.lastIndexOf(':');if(colon>=0){authority=authority.slice(0,colon);}" +
  "if(!/^[A-Za-z0-9._~!$&'()*+,;=%-]+$/.test(authority)){return '';}" +
  "return authority.toLowerCase();};" +
  "var patched=function(){var host=nativeGet.call(this);if(host!==''){return host;}" +
  "try{if(String(this.protocol).toLowerCase()==='dsh-resource:'){return hostOf(this.href);}}catch(e){}" +
  "return host;};" +
  "Object.defineProperty(U.prototype,'hostname',{configurable:true,enumerable:desc.enumerable,get:patched,set:desc.set});" +
  "}catch(e){}})();";
// __RESOURCE_URL_SHIM_END__

// 文档开始就装两颗桥：
//   1. 外链：查询用量/充值/账号信息都是 <a target="_blank">。ArkWeb 在
//      multiWindowAccess(false) 下拿不到新窗口处理器会把渲染进程挂住，表现就是
//      点一下整页白屏、返回也退不出去。这里在捕获阶段拦下所有 target=_blank
//      锚点：站外的交给系统浏览器，站内的就地导航，绝不让内核去开新窗口。
//   2. 下载：DSH 的「下载」是把文件读成 blob 再点一个 <a download> 锚点，ArkWeb
//      不会替页面保存 blob: 下载（没设置下载委托时就是静默失败）。这里在文档起点
//      接管所有 <a download>（含脚本直接 anchor.click()、会话导出、预览下载）：
//      把字节经 javaScriptProxy 分片交给 Index，壳层弹系统保存框写文件。
//      注意不要伪造 window.dshDesktop：引擎里多处用 `"dshDesktop" in globalThis`
//      判断桌面版（onboarding、分析、拖拽等），塞一个假对象会把 Web 版行为改坏。
const BRIDGE_DOCUMENT_SCRIPT: string =
  "(function(){try{" +
  // __DSH_NONCE__ 由 Index.bridgeDocumentScript() 换成每次启动的随机 UUID；
  // 终端/下载桥消息必须带这个 nonce，避免同源以外的页面伪造。
  "window.__dshNonce=__DSH_NONCE__;" +
  "if(window.__dshNativeBridge){return;}window.__dshNativeBridge=true;" +
  "var CH=262144;" +
  "var send=function(u){try{console.log('DSH_TERM:'+window.__dshNonce+':'+JSON.stringify({op:'openExternal',url:String(u)}));}catch(e){}};" +
  "var external=function(u){var s=String(u||'');if(!/^https?:/i.test(s)){return false;}send(s);return true;};" +
  "window.open=function(url){var s=String(url||'');var stub={closed:false,opener:null,focus:function(){},close:function(){stub.closed=true;},location:{replace:function(u){external(u);},assign:function(u){external(u);}}};try{Object.defineProperty(stub.location,'href',{get:function(){return s;},set:function(u){external(u);},configurable:true});}catch(e){}if(s&&s!=='about:blank'){external(s);}return stub;};" +
  "var nameOf=function(url,fallback){try{var n=decodeURIComponent(String(url).split('?')[0].split('#')[0].split('/').pop()||'');return n||fallback;}catch(e){return fallback;}};" +
  "var blank=function(a){if(!a||!a.getAttribute){return false;}var t=String(a.getAttribute('target')||'').toLowerCase();if(t!=='_blank'&&t!=='_new'){return false;}var u;try{u=new URL(a.href,document.baseURI);}catch(e){return false;}if(u.origin===location.origin){try{location.assign(u.href);}catch(e){}return true;}return external(u.href);};" +
  "var b64=function(blob){return new Promise(function(resolve,reject){try{var r=new FileReader();r.onload=function(){var s=String(r.result||'');resolve(s.slice(s.indexOf(',')+1));};r.onerror=function(){reject(new Error('read'));};r.readAsDataURL(blob);}catch(e){reject(e);}});};" +
  "var waits={};" +
  "window.__dshSaveDone=function(id,path){var cb=waits[id];if(cb){delete waits[id];cb(String(path||''));}};" +
  "var sendBlob=function(name,mime,data){return new Promise(function(resolve,reject){var go=function(left){if(!window.dshNative){if(left<=0){reject(new Error('bridge'));return;}setTimeout(function(){go(left-1);},100);return;}var total=Math.max(1,Math.ceil(data.length/CH));var id=window.__dshNonce+':d'+Date.now().toString(36)+Math.random().toString(36).slice(2);for(var i=0;i<total;i++){if(!window.dshNative.put(id,name,mime,total,i,data.slice(i*CH,(i+1)*CH))){reject(new Error('put'));return;}}var timer=setTimeout(function(){if(waits[id]){delete waits[id];resolve('');}},180000);waits[id]=function(p){clearTimeout(timer);resolve(p);};};go(20);});};" +
  "var saveUrl=function(url,name){return fetch(String(url),{referrerPolicy:'no-referrer'}).then(function(r){if(!r.ok){throw new Error('fetch');}return r.blob();}).then(function(blob){return b64(blob).then(function(data){return sendBlob(String(name||nameOf(url,'download')),blob.type||'',data);});});};" +
  "window.__dshSaveUrl=function(url,name){try{saveUrl(url,name).catch(function(){});}catch(e){}};" +
  "var download=function(a){if(!a||!a.hasAttribute||!a.hasAttribute('download')){return false;}var href=a.href;if(!href){return false;}if(href.indexOf('blob:')!==0&&!/^https?:/i.test(href)){return false;}try{saveUrl(href,a.getAttribute('download')||nameOf(href,'download')).catch(function(){});}catch(e){}return true;};" +
  "var proto=window.HTMLAnchorElement&&HTMLAnchorElement.prototype;" +
  "if(proto&&proto.click){var orig=proto.click;proto.click=function(){if(download(this)){return;}if(blank(this)){return;}return orig.apply(this,arguments);};}" +
  "document.addEventListener('click',function(e){try{var t=e.target;var a=t&&t.closest?t.closest('a[href]'):null;if(!a){return;}if(download(a)){e.preventDefault();e.stopPropagation();return;}if(blank(a)){e.preventDefault();e.stopPropagation();}}catch(err){}},true);" +
  "}catch(e){}})();";

// 下载桥配额（页面 → javaScriptProxy）。单分片 base64 文本 256 KiB、单任务
// 256 MiB、同时最多 8 个未完成任务；5 分钟内没凑齐的分片任务按超时清理。
const DOWNLOAD_CHUNK_LIMIT = 262144;
const DOWNLOAD_BYTES_LIMIT = 268435456;
const DOWNLOAD_JOB_LIMIT = 8;
const DOWNLOAD_JOB_TIMEOUT = 300000;

// javaScriptProxy 的落点：页面分片送来的下载内容。ArkTS 侧只在分片齐了之后才弹
// 系统保存框，写盘与回包都在 Index 里完成。
class DownloadSink {
  putImpl: (id: string, name: string, mime: string, total: number, seq: number, chunk: string) => boolean =
    () => false;
  put(id: string, name: string, mime: string, total: number, seq: number, chunk: string): boolean {
    return this.putImpl(id, name, mime, total, seq, chunk);
  }
}

interface DownloadJob {
  name: string;
  mime: string;
  total: number;
  got: number;
  // 已收到的 base64 解码后字节数（重复分片会先扣掉旧值），用于总大小上限。
  bytes: number;
  createdAt: number;
  parts: string[];
  filled: boolean[];
}

// 界面就是官方 Web GUI：设备内跑 `dsh --profile web`，Web 组件加载它打印的
// http://127.0.0.1:<port>。这里只保留启动/等待/失败三种状态，不再自绘会话界面。
@Entry
@Component
struct Index {
  @State private url: string = '';
  @State private showTerminal: boolean = false;
  // 宿主专有控制对象，不提供给网页或现有桥。
  private browserControl: BrowserControl = new BrowserControl();
  private browserConsent: BrowserConsentControl = new BrowserConsentControl();
  private browserBridge?: BrowserBridge;
  // 不可信的主 GUI 标签，不是会话认证凭据。
  private browserSessionId: string = '';
  private browserAgentEpoch: number = 0;
  private browserLaunchId: string = '';
  private browserLaunchSession: string = '';
  private browserLaunchDeadline: number = 0;
  private browserHostForeground: boolean = true;
  @State private browserAgentMessage: string = '';
  @State private browserAgentConnected: boolean = false;
  private stopBrowserAgent(message: string): void {
    this.browserAgentEpoch++;
    this.browserConsent.cancel();
    const bridge = this.browserBridge;
    this.browserBridge = undefined;
    try { bridge?.stop(); } catch (_error) {}
    this.browserAgentConnected = false;
    this.browserAgentMessage = message;
  }

  // 原生按钮或当前会话的工具请求可启动；凭据由 relay 私有发布，绝不交给网页。
  private startBrowserAgent(): void {
    this.stopBrowserAgent('');
    const runtime = this.runtime;
    if (!runtime || !this.browserAvailable() || this.browserControl.currentGeneration() === null ||
      this.browserSessionId === '') { this.browserAgentMessage = '浏览器或当前会话不可用'; return; }
    const epoch = ++this.browserAgentEpoch;
    const visibleSessionId = (): string | null => this.browserSessionId !== '' ? this.browserSessionId : null;
    const host: BrowserBridgeHost = {
      visibleSessionId: (): string | null => epoch === this.browserAgentEpoch && this.browserAvailable()
        ? visibleSessionId() : null,
      authorize: async (details: BrowserBridgeApproval): Promise<boolean> => {
        if (epoch !== this.browserAgentEpoch || !this.browserAvailable()) { return false; }
        if (epoch === this.browserAgentEpoch) {
          this.browserAgentMessage = 'Agent 请求：' + details.operation + '，等待确认。';
        }
        const allowed = await this.browserConsent.request(details);
        if (allowed && epoch === this.browserAgentEpoch && this.browserAvailable()) {
          this.browserAgentMessage = '已允许：' + details.operation + '。';
        }
        return allowed && epoch === this.browserAgentEpoch && this.browserAvailable();
      },
      automaticApproved: (details: BrowserBridgeApproval): void => {
        // Only a notice; the decision was made by the session's live preset.
        if (epoch !== this.browserAgentEpoch) { return; }
        this.browserAgentMessage = '已按当前会话权限自动放行：' + details.operation + '。';
      },
      deliverReady: async (ready: BrowserRelayReady): Promise<void> => {
        if (epoch !== this.browserAgentEpoch || !this.browserAvailable()) { throw new Error('Browser stopped'); }
        // relay 已发布凭据；这里只确认桥仍属于可见浏览器，不读取或写入凭据。
      },
      onClosed: (): void => {
        if (epoch === this.browserAgentEpoch) {
          this.browserConsent.cancel();
          this.browserAgentEpoch++;
          this.browserBridge = undefined;
          this.browserAgentConnected = false;
          this.browserAgentMessage = '浏览器 Agent 已关闭或发生错误；授权已取消。';
        }
      }
    };
    try {
      const bridge = new BrowserBridge(runtime, this.browserControl, host);
      this.browserBridge = bridge;
      bridge.start();
      if (epoch === this.browserAgentEpoch) {
        this.browserAgentConnected = true;
        this.browserAgentMessage = '浏览器 Agent 已连接；受限模式下每次操作仍需确认。';
      }
    } catch (_error) { this.stopBrowserAgent('浏览器 Agent 启动失败，授权已取消。'); }
  }
  @State private showBrowser: boolean = false;
  @State private browserLeft: number = 0;
  @State private browserTop: number = 0;
  @State private browserWidth: number = 0;
  @State private browserHeight: number = 0;
  @State private browserVisible: boolean = false;
  @State private stageWidth: number = 0;
  @State private stageHeight: number = 0;
  // 右侧栏终端 tab 的矩形（页面 CSS 像素 == vp），由页面的桥消息更新。
  @State private termLeft: number = 0;
  @State private termTop: number = 0;
  @State private termWidth: number = 0;
  @State private termHeight: number = 0;
  @State private termVisible: boolean = false;
  // 当前 DSH 会话的工作目录，由页面插件从宿主 API 解析后下发；终端用它作为 cwd。
  @State private termCwd: string = '';
  // 当前终端 tab 的 owner。壳层只有一路原生终端（插件注册为 multiple:false），
  // 这里记录 owner 只是为了忽略旧 tab / 迟到消息，避免它们改掉现有终端的几何
  // 或把它关掉。
  private termOwner: string = '';
  @State private status: string = '正在准备原生运行时';
  @State private detail: string = '';
  @State private failed: string = '';
  @State private busy: boolean = false;
  // Web GUI 自己也是异步启动的：页面 onPageEnd 只代表静态资源加载完，
  // 此时工作区/会话还在恢复，输入框和右栏按钮都还没就绪。先由原生启动页
  // 盖住 Web，等首个会话真正挂载后再露出界面，避免用户点到半成品 UI。
  @State private webReady: boolean = false;
  // 只有真的在解包时才提示「首次启动需要 1–2 分钟」；普通冷启动不该看到这句。
  @State private unpacking: boolean = false;
  private bootTimer: number = -1;
  private readyTimer: number = -1;
  private absoluteTimer: number = -1;
  private runtime?: NativeRuntime;
  private guard?: PluginGuard;
  private keepAlive: BackgroundKeepAlive = new BackgroundKeepAlive();
  private context?: common.UIAbilityContext;
  // 下载：页面通过 javaScriptProxy 分片送来的内容，齐了之后弹系统保存框。
  private downloads: Map<string, DownloadJob> = new Map();
  private downloadSink: DownloadSink = new DownloadSink();
  // 终端/下载桥的每次启动随机 nonce：只认注入到本地页面里的消息与下载任务。
  // UUID v4 由安全随机数生成，第三方页面拿不到同一文档里的 window.__dshNonce。
  private bridgeNonce: string = util.generateRandomUUID(true);
  private downloadTimer: number = -1;
  // 最后一次成功采样页面状态的时刻。渲染进程被新窗口请求挂住时轮询会停，
  // onBackPress 不能再拿残留的浮层状态把返回吞掉（白屏退不出去）。
  private uiAliveAt: number = 0;
  private controller: webview.WebviewController = new webview.WebviewController();
  private barTimer: number = -1;
  private keepAliveTimer: number = -1;
  private uiTimer: number = -1;
  // 页面浮层状态（返回手势按优先级逐层关闭）：
  //   menu 菜单 / dialog 设置等对话框 / right 右侧栏 / nav 左侧抽屉 / hero 首页 / conv 会话
  private webMenu: boolean = false;
  private webDialog: boolean = false;
  private webRight: boolean = false;
  private webNav: boolean = false;
  private keepAliveOn: boolean = false;
  @State private barDark: boolean = false;
  // 页面要给前摄挖孔 / 状态栏（top）和底部手势条（bottom）让出的高度（vp）。
  // 两种模式都保持全屏布局，所以上下都靠这两项留边；非沉浸式顶部等于状态栏
  // 高度，沉浸式顶部等于挖孔底边再加一点余量。
  @State private insetTop: number = 0;
  @State private insetBottom: number = 0;
  // 设置里的「显示系统状态栏与底部手势条」（harmony-native.json）。
  @State private systemBarsOn: boolean = false;
  private systemBarsApplied: boolean = false;
  // 安全模式隔离提示：Web GUI 已经起来时用浮层提示还剩多少个插件被停用。
  @State private quarantineCount: number = 0;
  @State private quarantineError: string = '';
  private autoRestoreScheduled: boolean = false;
  @State private barBg: string = '';

  aboutToAppear(): void {
    try { this.context = this.getUIContext().getHostContext() as common.UIAbilityContext; } catch (error) { /* 取不到上下文时延后处理 */ }
    this.downloadSink.putImpl = (id: string, name: string, mime: string, total: number, seq: number, chunk: string): boolean => {
      return this.onDownloadChunk(id, name, mime, total, seq, chunk);
    };
    // 分片任务可能永远凑不齐：定时把超时的任务从 Map 里删掉，避免占内存。
    if (this.downloadTimer < 0) {
      this.downloadTimer = setInterval(() => { this.cleanupDownloads(); }, 60000);
    }
    this.systemBarsOn = this.readShowSystemBarsEarly();
    this.followSystemBars();
    this.startUiWatch();
    this.boot();
  }

  // EntryAbility 启动时已按镜像文件设过窗口模式；Index 在 runtime 创建前也会
  // 走一次 applyBars()，这里先把开关读进来，避免顶部留白按默认的「沉浸式」
  // 算、开局跳一下。
  private readShowSystemBarsEarly(): boolean {
    try {
      const context = this.context;
      if (!context) { return false; }
      const file = context.filesDir + '/harness-home/harmony-native.json';
      if (!fs.accessSync(file)) { return false; }
      const parsed = JSON.parse(fs.readTextSync(file)) as Record<string, boolean>;
      return parsed.showSystemBars === true;
    } catch (error) { return false; }
  }

  // 返回手势需要同步判断页面上的浮层，runJavaScript 是异步的：这里每 500ms
  // 采样一次页面状态，onBackPress 里按优先级动作。
  private startUiWatch(): void {
    if (this.uiTimer >= 0) { return; }
    const script =
      "(function(){try{" +
      "var d=document.querySelector('[role=dialog][aria-label=\"导航\"]');" +
      "var s=document.querySelector('[data-conversation-session]');" +
      "var ready=!!s&&(s.getAttribute('data-conversation-session')||'').length>0;" +
      "var boot=!!document.querySelector('[data-dsh-boot]');" +
      "var home=!boot&&!!document.querySelector('[data-composer-seat]');" +
      "var nav=!!d&&d.getAttribute('aria-modal')==='true';" +
      "var other=document.querySelector('[role=dialog]:not([aria-label=\"导航\"])');" +
      "var menu=!!document.querySelector('[role=menu]');" +
      "var rb=document.querySelector('[aria-label=\"收起右侧边栏\"]');" +
      "var right=!!rb&&getComputedStyle(rb).visibility!=='hidden'&&rb.getBoundingClientRect().width>0;" +
      "return JSON.stringify({nav:nav,dialog:!!other,menu:menu,right:right,ready:ready,home:home,session:s?s.getAttribute('data-conversation-session'):''});" +
      "}catch(e){return '{}';}})()";
    this.uiTimer = setInterval(() => {
      if (this.url === '') { return; }
      this.pollBrowserLaunch();
      try {
        this.controller.runJavaScript(script).then((result: string) => {
          try {
            this.uiAliveAt = Date.now();
            let text = String(result);
            if (text.startsWith('"')) { text = JSON.parse(text) as string; }
            const state = JSON.parse(text) as Record<string, Object>;
            const session = typeof state['session'] === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(state['session'] as string)
              ? state['session'] as string : '';
            if (session !== this.browserSessionId) {
              this.browserSessionId = session;
              if (this.browserBridge) { this.stopBrowserAgent('当前会话已变化，浏览器 Agent 已停止。'); }
            }
            if (state['ready'] === true) { this.markWebReady(); }
            else if (state['home'] === true) { this.armReadyFallback(); }
            this.webNav = state['nav'] === true;
            this.webDialog = state['dialog'] === true;
            this.webMenu = state['menu'] === true;
            this.webRight = state['right'] === true;
          } catch (error) { /* 解析失败时保留上一次状态 */ }
        }).catch(() => {});
      } catch (error) { /* Web 未挂载 */ }
    }, 500);
  }

  // Same-UID request carries only a session label; it never authorizes an
  // operation. The GUI must still show that session and the normal bridge
  // performs its per-operation page, session and approval checks.
  private pollBrowserLaunch(): void {
    try {
      if (!this.context || !this.browserHostForeground) { return; }
      const file = this.context.filesDir + '/browser-managed/launch-request.json';
      if (!fs.accessSync(file)) { this.browserLaunchSession = ''; return; }
      const stat = fs.lstatSync(file);
      if (stat.isSymbolicLink() || !stat.isFile() || stat.size > 1024) { return; }
      const request = JSON.parse(fs.readTextSync(file)) as Record<string, Object>;
      const id = request['id'];
      const session = request['sessionId'];
      const deadline = Number(request['deadline']);
      if (request['version'] !== 1 || typeof id !== 'string' || !/^[a-f0-9]{32}$/.test(id) ||
        typeof session !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(session) ||
        !Number.isSafeInteger(deadline) || deadline <= Date.now() || deadline > Date.now() + 20000) { return; }
      if (id !== this.browserLaunchId) {
        this.browserLaunchId = id;
        this.browserLaunchSession = session;
        this.browserLaunchDeadline = deadline;
        const script = '(function(){return typeof window.__dshOpenAgentBrowser === "function" && ' +
          'window.__dshOpenAgentBrowser(' + JSON.stringify(session) + ');})()';
        this.controller.runJavaScript(script).then((result: string) => {
          if (String(result) === 'true' && this.browserLaunchId === id) {
            this.showBrowser = true;
          } else if (this.browserLaunchId === id) { this.browserLaunchId = ''; }
        }).catch(() => { if (this.browserLaunchId === id) { this.browserLaunchId = ''; } });
      }
      if (this.browserLaunchSession === this.browserSessionId && Date.now() < this.browserLaunchDeadline &&
        this.browserAvailable() && this.browserControl.currentGeneration() !== null && !this.browserBridge) {
        this.browserLaunchSession = '';
        this.startBrowserAgent();
      }
    } catch (_error) { /* absent, incomplete, or untrusted request */ }
  }

  private pressEscape(): void {
    try {
      this.controller.runJavaScript(
        "(function(){try{document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',code:'Escape',bubbles:true}));" +
        "setTimeout(function(){try{if(document.activeElement)document.activeElement.blur();}catch(e){}},250);}catch(e){}})()"
      ).catch(() => {});
    } catch (error) { /* Web 未挂载 */ }
  }

  private clickSidebarToggle(): void {
    try {
      this.controller.runJavaScript(
        "(function(){try{var es=[].slice.call(document.querySelectorAll('[aria-label=\"打开侧边栏\"]'));" +
        "for(var i=0;i<es.length;i++){if(es[i].getBoundingClientRect().x>=0){" +
        "es[i].click();es[i].blur();if(document.activeElement)document.activeElement.blur();return;}}}catch(e){}})()"
      ).catch(() => {});
    } catch (error) { /* Web 未挂载 */ }
  }

  // 菜单没有 Escape 处理，点它自己的触发按钮（aria-expanded=true）才会收起。
  private closeMenu(): void {
    try {
      this.controller.runJavaScript(
        "(function(){try{var es=[].slice.call(document.querySelectorAll('[aria-haspopup=menu][aria-expanded=true]'));" +
        "for(var i=0;i<es.length;i++){if(es[i].getBoundingClientRect().x>=0){" +
        "es[i].click();es[i].blur();if(document.activeElement)document.activeElement.blur();return;}}}catch(e){}})()"
      ).catch(() => {});
    } catch (error) { /* Web 未挂载 */ }
  }

  onPageShow(): void { this.browserHostForeground = true; }
  onPageHide(): void { this.browserHostForeground = false; this.browserLaunchSession = ''; this.stopBrowserAgent('应用已进入后台，浏览器 Agent 已停止。'); }

  aboutToDisappear(): void {
    this.stopBrowserAgent('页面已销毁，浏览器 Agent 已停止。');
    this.browserConsent.destroy();
    if (this.barTimer >= 0) { clearInterval(this.barTimer); this.barTimer = -1; }
    if (this.readyTimer >= 0) { clearTimeout(this.readyTimer); this.readyTimer = -1; }
    if (this.absoluteTimer >= 0) { clearTimeout(this.absoluteTimer); this.absoluteTimer = -1; }
    if (this.keepAliveTimer >= 0) { clearInterval(this.keepAliveTimer); this.keepAliveTimer = -1; }
    if (this.uiTimer >= 0) { clearInterval(this.uiTimer); this.uiTimer = -1; }
    if (this.downloadTimer >= 0) { clearInterval(this.downloadTimer); this.downloadTimer = -1; }
    this.stopUnpackingWatch();
    this.runtime?.stopWebUI();
    const context = this.context;
    if (context) { this.keepAlive.stop(context); }
  }

  // 系统返回手势的语义：
  //  1. 终端浮层可见时先收起右侧栏，会话继续跑（只有 tab 的 × 才停止会话）；
  //  2. 其余情况交给 Web 自己返回（历史/路由），与浏览器的返回一致；
  //  3. Web 没有可回退的历史时再交回系统（退到后台/退出）。
  private collapseRightSidebar(): void {
    try {
      this.controller.runJavaScript(
        "(function(){try{if(window.__dshCollapseRightSidebar)window.__dshCollapseRightSidebar();}catch(e){}" +
        "var es=[].slice.call(document.querySelectorAll('[aria-label]'));" +
        "for(var i=0;i<es.length;i++){var a=es[i].getAttribute('aria-label')||'';" +
        "if(/^(collapse|收起)\\b.*(right sidebar|右侧边栏)$/i.test(a)){es[i].click();break;}}" +
        "setTimeout(function(){try{if(document.activeElement)document.activeElement.blur();}catch(e){}},250);" +
        "})()"
      ).catch(() => {});
    } catch (error) { /* Web 未挂载 */ }
  }

  onBackPress(): boolean {
    if (this.browserActuallyVisible()) {
      this.closeBrowser();
      return true;
    }
    // 页面若已经跑到站外（onLoadIntercept 的兜底没拦住），先把本地界面拉回来，
    // 不给用户留一个退不出去的白页。
    try {
      const current = this.controller.getUrl();
      if (current !== '' && this.url !== '' && !this.isLocalUrl(current)) {
        this.controller.loadUrl(this.url);
        return true;
      }
    } catch (error) { /* 控制器未就绪时按默认处理 */ }
    // 渲染进程被新窗口请求挂住时轮询会停（uiAliveAt 不再更新）：这时残留的浮层
    // 状态不可信，直接交给 Web 历史/系统，否则返回会被 pressEscape 一直吃掉。
    const alive = Date.now() - this.uiAliveAt < 2500;
    if (alive) {
      // 按浮层优先级逐层关闭：菜单 → 对话框（设置）→ 右侧栏/终端 → 左侧抽屉。
      if (this.webMenu) { this.closeMenu(); return true; }
      if (this.webDialog) { this.pressEscape(); return true; }
      if (this.termVisible || this.webRight) { this.collapseRightSidebar(); return true; }
      if (this.webNav) { this.clickSidebarToggle(); return true; }
    }
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward();
        return true;
      }
    } catch (error) { /* 控制器未就绪时退回系统默认行为 */ }
    return false;
  }

  // 后台保活由 DSH 插件（设置 → 通用 → 鸿蒙适配）控制：插件把开关镜像到
  // harness-home/harmony-native.json，这里每秒读一次，变化时启停连续任务。
  private applyKeepAlive(): void {
    const context = this.context;
    const runtime = this.runtime;
    if (!context || !runtime) { return; }
    const want = runtime.readKeepAlive();
    if (want === this.keepAliveOn) { return; }
    if (want) {
      this.keepAlive.start(context).then((started: boolean) => { this.keepAliveOn = started; }).catch(() => {});
    } else {
      this.keepAlive.stop(context).catch(() => {});
      this.keepAliveOn = false;
    }
  }

  // 系统栏开关（同一个镜像文件）：切换系统栏可见性，窗口始终全屏布局。
  // 与 EntryAbility 的初始设置走同一套语义。
  private applySystemBars(): void {
    const runtime = this.runtime;
    const context = this.context;
    if (!runtime || !context) { return; }
    const want = runtime.readShowSystemBars();
    if (this.systemBarsApplied && want === this.systemBarsOn) { return; }
    this.systemBarsApplied = true;
    this.systemBarsOn = want;
    window.getLastWindow(context).then((win: window.Window) => {
      this.applyWindowMode(win);
      // 布局模式/可见性变了，重新取避让区并同步栏色。
      this.applyBars(this.barDark, this.barBg);
    }).catch(() => {});
  }

  // 沉浸式 / 非沉浸式靠系统栏可见性区分（窗口始终全屏布局，不切回安全区）：
  //   沉浸式：隐藏系统栏，日常只留主题背景；系统栏由系统在顶部下滑时临时露出。
  //   非沉浸式：显示系统状态栏，内容下移到状态栏下方。
  private applyWindowMode(win: window.Window): void {
    try { win.setWindowLayoutFullScreen(true); } catch (error) { /* 忽略 */ }
    setSystemBarVisible(win, this.systemBarsOn);
    this.updateInsets(win);
  }

  // 系统主题变化时先按系统色把状态栏/导航栏刷成同色，避免 Web 还没加载时的白条。
  private followSystemBars(): void {
    // mediaquery 在这台设备上会返回错误的 matches，先用 Ability 的配置色模式定基调；
    // 这里拿不准就会让底层背景停留在浅色，键盘滑入时露出白块。
    try {
      const dark = this.context?.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      this.barDark = dark;
      this.applyBars(dark, dark ? '#101113' : '#F7F7F0');
    } catch (error) { /* 取不到配置就保持默认 */ }
    try {
      const mq = mediaquery.matchMediaSync('(dark-mode: true)');
      // 不采用 mq.matches 的初始值：它可能和真实系统色不一致，交给页面同步兜底。
      mq.on('change', (event: mediaquery.MediaQueryResult) => {
        this.barDark = event.matches;
        this.applyBars(this.barDark, this.barDark ? '#101113' : '#F7F7F0');
      });
    } catch (error) { /* 取系统主题失败就保持默认 */ }
  }

  // 官方 Web GUI 的主题可以手动切换，读取页面主题来同步系统栏。
  private syncBarsFromPage(): void {
    if (this.url === '') { return; }
    try {
      // 依次试 body、html、DSH 的 CSS 变量：任何一个是实色就用它，
      // 这样系统栏和页面背景是同一个颜色，不会出现「深色主题下栏更浅」。
      const script =
        "(function(){var d=document.documentElement,b=document.body;if(!d||!b)return '{}';" +
        "var pick=function(c){return c&&c!=='transparent'&&c.indexOf('rgba(0, 0, 0, 0)')<0&&c.indexOf('rgba(0,0,0,0)')<0;};" +
        "var cands=[getComputedStyle(b).backgroundColor,getComputedStyle(d).backgroundColor," +
        "getComputedStyle(d).getPropertyValue('--dsw-alias-bg-base').trim()," +
        "getComputedStyle(d).getPropertyValue('--dsw-alias-bg-l1').trim()];" +
        "var bg='';for(var i=0;i<cands.length;i++){if(pick(cands[i])){bg=cands[i];break;}}" +
        "var scheme=d.style.colorScheme||getComputedStyle(d).colorScheme;" +
        "var dark=scheme==='dark'||(scheme!=='light'&&window.matchMedia('(prefers-color-scheme: dark)').matches);" +
        "return JSON.stringify({dark:dark,bg:bg});})()";
      this.controller.runJavaScript(script).then((result: string) => {
        try {
          // ArkWeb 的 runJavaScript 有时把字符串结果再 JSON 编码一层（外层带引号），
          // 只解一次会得到 string，parsed.dark 恒为 undefined，背景就永远停在浅色回退值。
          let text: string = result;
          if (text.startsWith('"')) {
            try { text = JSON.parse(text) as string; } catch (error) { /* 不是双层编码 */ }
          }
          const parsed = JSON.parse(text) as Record<string, string | boolean>;
          const dark = parsed.dark === true;
          const bg = typeof parsed.bg === 'string' ? parsed.bg : '';
          if (dark === this.barDark && bg === this.barBg) { return; }
          this.applyBars(dark, bg !== '' ? bg : (dark ? '#101113' : '#F7F7F0'));
        } catch (error) { /* 页面还没就绪 */ }
      }).catch(() => {});
    } catch (error) { /* Web 未挂载 */ }
  }

  // ArkUI 的 backgroundColor / setWindowBackgroundColor 只认 #RRGGBB（或 #AARRGGBB）。
  // 页面里 getComputedStyle 返回的是 "rgb(16, 17, 19)"，直接传下去会被当成非法颜色，
  // 底层回落到白色——软键盘滑入时露出的那块白就是这一层。
  private normalizeColor(color: string): string {
    const text = color.trim();
    if (text === '') { return ''; }
    if (/^#[0-9a-fA-F]{6}$/.test(text)) { return text.toUpperCase(); }
    const rgb = /^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})/.exec(text);
    if (rgb) {
      const values: number[] = [Number(rgb[1]), Number(rgb[2]), Number(rgb[3])];
      let out = '#';
      for (const value of values) {
        if (!Number.isFinite(value)) { return ''; }
        const clamped = Math.max(0, Math.min(255, Math.round(value)));
        out += clamped.toString(16).padStart(2, '0');
      }
      return out.toUpperCase();
    }
    return '';
  }

  // window.open / <a target="_blank"> 在 ArkWeb 里都走「新窗口」通道：没有处理器时
  // 渲染进程会被挂住（白屏）。文档开始时已经注入 BRIDGE_DOCUMENT_SCRIPT，这里在
  // 页面加载完再补一次，覆盖文档起点注入失败（例如页面被替换）的情况。
  private installPopupBridge(): void {
    try { this.controller.runJavaScript(this.bridgeDocumentScript()).catch(() => {}); } catch (error) { /* Web 未挂载 */ }
  }
  // 把文档起点脚本里的 nonce 占位符换成当前实例的随机值；脚本内容变了，
  // ArkWeb 也不会把它当成重复脚本跳过首次注入。
  private bridgeDocumentScript(): string {
    return BRIDGE_DOCUMENT_SCRIPT.replace('__DSH_NONCE__', JSON.stringify(this.bridgeNonce));
  }
  private openExternal(url: string): void {
    if (!/^https?:\/\//i.test(url)) { return; }
    const context = this.context;
    if (!context) { return; }
    try { context.openLink(url).catch(() => {}); } catch (error) { /* 没有可用浏览器 */ }
  }
  // 当前 Web 服务的 origin（http://127.0.0.1:<port>）。页面自己发起的站内请求
  // 必须放行，其余主框架导航一律交给系统浏览器，避免 Web 组件跑出本地界面。
  private localOrigin(): string {
    if (this.url === '') { return ''; }
    try {
      const parsed = new url.URL(this.url);
      return parsed.origin;
    } catch (error) { return ''; }
  }
  // 用 URL 解析后比较 origin，避免 `http://127.0.0.1:8080.evil.com` 这类前缀绕过。
  private isLocalUrl(target: string): boolean {
    const origin = this.localOrigin();
    if (origin === '') { return false; }
    try {
      const parsed = new url.URL(target);
      const scheme = parsed.protocol.toLowerCase().replace(/:$/, '');
      return (scheme === 'http' || scheme === 'https') && parsed.origin === origin;
    } catch (error) { return false; }
  }
  // javascriptOnDocumentStart 只注入本地 origin；url 未就绪时返回空数组（不注入），
  // 不用 '*' 兜底。
  private documentScriptRules(): string[] {
    const origin = this.localOrigin();
    return origin === '' ? [] : [origin];
  }
  // javaScriptProxy.permission：对象级只放行本地 http origin，端口取运行时值。
  // 端口解析不到时给空列表，等于 DSH 桥不可用（页面处于异常状态，宁可失败关闭）。
  private proxyPermission(): string {
    let port = '';
    try {
      if (this.url !== '') {
        const parsed = new url.URL(this.url);
        port = parsed.port;
      }
    } catch (error) { port = ''; }
    if (port === '') { return '{"javascriptProxyPermission":{"urlPermissionList":[],"methodList":[]}}'; }
    return '{"javascriptProxyPermission":{"urlPermissionList":[{"scheme":"http","host":"127.0.0.1"' +
      ',"port":' + JSON.stringify(port) + ',"path":""}],"methodList":[]}}';
  }
  // 文件名只保留最后一段并去掉文件系统非法字符：系统保存框的 newFileNames 不接受路径。
  private safeFileName(name: string): string {
    let base = name;
    const slash = base.lastIndexOf('/');
    if (slash >= 0) { base = base.slice(slash + 1); }
    base = base.replace(/[\\/:*?"<>|]/g, '_').trim();
    if (base === '' || base === '.' || base === '..') { base = 'download'; }
    return base;
  }
  private nameFromUrl(url: string): string {
    try {
      const clean = url.split('#')[0].split('?')[0];
      const base = decodeURIComponent(clean.slice(clean.lastIndexOf('/') + 1));
      return base === '' ? 'download' : base;
    } catch (error) { return 'download'; }
  }
  // javaScriptProxy：页面把下载内容分片送过来。分片齐了才弹保存框，避免用户
  // 选完位置还要等数据；写盘结束后用 __dshSaveDone 把路径回给页面的 Promise。
  // 分片必须带本次启动的 nonce 前缀；并对单分片、总字节、并发任务数设上限。
  onDownloadChunk(id: string, name: string, mime: string, total: number, seq: number, chunk: string): boolean {
    if (id.indexOf(this.bridgeNonce + ':') !== 0) { return false; }
    if (id === '' || total <= 0 || total > 4096 || seq < 0 || seq >= total) { return false; }
    if (chunk.length > DOWNLOAD_CHUNK_LIMIT) { return false; }
    const chunkBytes = this.base64Bytes(chunk);
    if (chunkBytes > DOWNLOAD_BYTES_LIMIT) { return false; }
    this.cleanupDownloads();
    let job = this.downloads.get(id);
    if (job === undefined) {
      if (this.downloads.size >= DOWNLOAD_JOB_LIMIT) { return false; }
      const parts: string[] = [];
      const filled: boolean[] = [];
      for (let i = 0; i < total; i++) { parts.push(''); filled.push(false); }
      const created: DownloadJob = {
        name: name, mime: mime, total: total, got: 0, bytes: 0, createdAt: Date.now(),
        parts: parts, filled: filled
      };
      this.downloads.set(id, created);
      job = created;
    }
    if (job.total !== total) { return false; }
    if (job.filled[seq]) {
      // 同一分片重发时先扣掉旧长度，避免重复消息把 bytes 上限刷爆。
      job.bytes -= this.base64Bytes(job.parts[seq]);
    } else {
      job.filled[seq] = true;
      job.got += 1;
    }
    job.parts[seq] = chunk;
    job.bytes += chunkBytes;
    if (job.bytes > DOWNLOAD_BYTES_LIMIT) {
      this.downloads.delete(id);
      return false;
    }
    if (job.got >= job.total) {
      this.downloads.delete(id);
      const done = job;
      this.saveDownload(id, done).catch(() => { this.replyDownload(id, ''); });
    }
    return true;
  }
  // 分片任务可能永远等不到最后一个分片：按创建时间惰性清理，定时器兜底。
  private cleanupDownloads(): void {
    if (this.downloads.size === 0) { return; }
    const now = Date.now();
    const expired: string[] = [];
    this.downloads.forEach((job: DownloadJob, id: string) => {
      if (now - job.createdAt >= DOWNLOAD_JOB_TIMEOUT) { expired.push(id); }
    });
    for (const id of expired) { this.downloads.delete(id); }
  }
  // 页面送来的分片是 base64 字符串：按长度估算解码后字节数（含 '=' 补齐）。
  private base64Bytes(chunk: string): number {
    const length = chunk.length;
    if (length === 0) { return 0; }
    let padding = 0;
    if (chunk.endsWith('==')) { padding = 2; } else if (chunk.endsWith('=')) { padding = 1; }
    return Math.floor(length / 4) * 3 - padding;
  }
  private async saveDownload(id: string, job: DownloadJob): Promise<void> {
    const context = this.context;
    if (context === undefined) { this.replyDownload(id, ''); return; }
    const bytes = new util.Base64Helper().decodeSync(job.parts.join(''));
    const buffer = new ArrayBuffer(bytes.length);
    new Uint8Array(buffer).set(bytes);
    const viewPicker = new picker.DocumentViewPicker(context);
    const selected = await viewPicker.save({ newFileNames: [this.safeFileName(job.name)] });
    if (selected.length === 0) { this.replyDownload(id, ''); return; }
    const file = fs.openSync(selected[0], fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      let offset = 0;
      while (offset < buffer.byteLength) {
        const written = fs.writeSync(file.fd, buffer.slice(offset));
        if (written <= 0) { throw new Error('文件写入未完成'); }
        offset += written;
      }
      fs.fsyncSync(file.fd);
    } finally { fs.closeSync(file); }
    this.replyDownload(id, selected[0]);
  }
  private replyDownload(id: string, path: string): void {
    try {
      this.controller.runJavaScript('window.__dshSaveDone(' + JSON.stringify(id) + ',' + JSON.stringify(path) + ')')
        .catch(() => {});
    } catch (error) { /* Web 未挂载 */ }
  }
  // console 消息拿不到框架信息：http(s) 来源必须是本 Web 服务；空来源、VM/控制台
  // 以及 blob: 等没有可比较 origin 的来源交给 nonce 兜底，避免误伤页面自己的桥。
  private isLocalConsoleSource(sourceId: string): boolean {
    if (sourceId === '') { return true; }
    const lower = sourceId.toLowerCase();
    if (lower.indexOf('http://') !== 0 && lower.indexOf('https://') !== 0) { return true; }
    try {
      const parsed = new url.URL(sourceId);
      return parsed.origin === this.localOrigin();
    } catch (error) { return false; }
  }
  // 页面 → 壳层：DSH 客户端插件把终端 tab 的 open/bounds/visible/close 以
  // `console.log('DSH_TERM:<nonce>:' + json)` 发过来，没有 JS 代理也能用。
  //
  // 页面插件注册为单实例（multiple:false），所以壳层只需维护一路终端；owner
  // 仍然参与判断：迟到的旧 tab 消息不能改几何，更不能把现有终端关掉。
  private termOwnerMatches(owner: string): boolean {
    return owner === '' || this.termOwner === '' || owner === this.termOwner;
  }

  // 把页面上报矩形裁到当前容器，屏幕旋转或键盘改变大小后也重新裁剪。
  private browserClipLeft(): number { return Math.max(0, Math.min(this.stageWidth, this.browserLeft)); }
  private browserClipTop(): number { return Math.max(0, Math.min(this.stageHeight, this.browserTop)); }
  private browserClipWidth(): number {
    return Math.max(0, Math.min(this.stageWidth, this.browserLeft + this.browserWidth) - this.browserClipLeft());
  }
  private browserClipHeight(): number {
    return Math.max(0, Math.min(this.stageHeight, this.browserTop + this.browserHeight) - this.browserClipTop());
  }
  private browserActuallyVisible(): boolean {
    // 启动遮罩必须吃掉触摸；两个原生 tab 同时报可见时终端在上层。
    return this.webReady && this.showBrowser && this.browserVisible &&
      !(this.showTerminal && this.termVisible) && this.browserClipWidth() > 1 && this.browserClipHeight() > 1;
  }
  private browserAvailable(): boolean {
    return this.browserHostForeground && this.webReady && this.showBrowser && this.browserSessionId !== '';
  }

  private closeBrowser(): void {
    this.stopBrowserAgent('浏览器已关闭，浏览器 Agent 已停止。');
    this.showBrowser = false;
    this.browserVisible = false;
    this.browserSessionId = '';
    this.browserControl.setVisible(false);
    try {
      this.controller.runJavaScript(
        '(function(){if(window.__dshBrowserClosed)window.__dshBrowserClosed();})()'
      ).catch(() => {});
    } catch (error) { /* Web 未挂载 */ }
  }

  private onTermBridge(text: string): void {
    const prefix = 'DSH_TERM:' + this.bridgeNonce + ':';
    if (text.indexOf(prefix) !== 0) { return; }
    try {
      const message = JSON.parse(text.slice(prefix.length)) as Record<string, Object>;
      const op = message['op'] as string;
      const owner = typeof message['owner'] === 'string' ? message['owner'] as string : '';
      if (op === 'browserOpen') {
        // 页面只能请求展示空面板，不能指定原生浏览器的初始地址。
        this.showBrowser = true;
        this.browserVisible = false;
        if (!this.browserAgentConnected) { this.browserAgentMessage = ''; }
      } else if (op === 'browserBounds') {
        const label = message['sessionId'];
        const sessionId = typeof label === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(label) ? label : '';
        if (sessionId !== this.browserSessionId) {
          this.browserSessionId = sessionId;
          if (this.browserBridge) { this.stopBrowserAgent('当前会话已变化，浏览器 Agent 已停止。'); }
        }
        const left = Number(message['left']);
        const top = Number(message['top']);
        const width = Number(message['width']);
        const height = Number(message['height']);
        if (!Number.isFinite(left) || !Number.isFinite(top) ||
          !Number.isFinite(width) || !Number.isFinite(height)) { return; }
        this.browserLeft = left;
        this.browserTop = top;
        this.browserWidth = Math.max(1, width);
        this.browserHeight = Math.max(1, height);
        this.browserVisible = message['visible'] === true && width > 1 && height > 1;
        this.showBrowser = true;
      } else if (op === 'browserVisible') {
        this.browserVisible = message['visible'] === true;
      } else if (op === 'browserClose') {
        this.stopBrowserAgent('浏览器已关闭，浏览器 Agent 已停止。');
        this.showBrowser = false;
        this.browserVisible = false;
        this.browserSessionId = '';
      } else if (op === 'open') {
        if (!this.termOwnerMatches(owner)) { return; }
        if (owner !== '') { this.termOwner = owner; }
        this.showTerminal = true;
        this.termVisible = false;
        const cwd = message['cwd'] as string;
        if (typeof cwd === 'string' && cwd !== '') { this.termCwd = cwd; }
      } else if (op === 'cwd') {
        // 页面从宿主 API 拿到当前会话的工作目录后补发过来，终端跟随它。
        // cwd 是会话级状态，不属于某个 tab，所以不按 owner 过滤。
        const cwd = message['cwd'] as string;
        if (typeof cwd === 'string' && cwd !== '') { this.termCwd = cwd; }
      } else if (op === 'ui') {
        // 页面在浮层变化时立即推送（比轮询快），返回手势用这份状态。
        this.webNav = message['nav'] === true;
        this.webDialog = message['dialog'] === true;
        this.webMenu = message['menu'] === true;
        this.webRight = message['right'] === true;
      } else if (op === 'bounds') {
        if (!this.termOwnerMatches(owner)) { return; }
        const left = Number(message['left']);
        const top = Number(message['top']);
        const width = Number(message['width']);
        const height = Number(message['height']);
        if (!Number.isFinite(left) || !Number.isFinite(top) ||
          !Number.isFinite(width) || !Number.isFinite(height)) { return; }
        if (owner !== '' && this.termOwner === '') { this.termOwner = owner; }
        this.termLeft = left;
        this.termTop = top;
        this.termWidth = Math.max(1, width);
        this.termHeight = Math.max(1, height);
        this.termVisible = message['visible'] === true && this.termWidth > 1 && this.termHeight > 1;
        this.showTerminal = true;
      } else if (op === 'visible') {
        if (!this.termOwnerMatches(owner)) { return; }
        this.termVisible = message['visible'] === true;
      } else if (op === 'focus') {
        if (!this.termOwnerMatches(owner)) { return; }
        // 页面要求聚焦终端输入框时再弹键盘：终端 tab 打开本身不抢焦点，
        // 否则横屏下键盘一上来就把仅剩的几行终端压没了。
        try { this.getUIContext().getFocusController().requestFocus('term-input'); } catch (error) { /* 未挂载 */ }
      } else if (op === 'openExternal') {
        const url = message['url'] as string;
        if (typeof url === 'string') { this.openExternal(url); }
      } else if (op === 'close') {
        // 只关掉匹配的 owner：多个标签时代（旧版插件）关一个不能把共用终端关掉。
        if (!this.termOwnerMatches(owner)) { return; }
        this.showTerminal = false;
        this.termVisible = false;
        this.termOwner = '';
      }
    } catch (error) { /* 不是桥消息，忽略 */ }
    this.browserControl.setVisible(this.browserAvailable());
  }

  private applyBars(dark: boolean, background: string): void {
    const fallback = dark ? '#101113' : '#F7F7F0';
    const normalized = this.normalizeColor(background);
    this.barDark = dark;
    this.barBg = normalized !== '' ? normalized : fallback;
    const context = this.context;
    if (!context) { return; }
    window.getLastWindow(context).then((win: window.Window) => {
      // 两种模式都是全屏布局：系统栏透明地盖在应用背景上，栏区露出的就是主题色。
      // 非沉浸式也走透明栏，避免设备把栏区刷成系统白底；显示与否由系统栏开关控制。
      try {
        win.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          navigationBarColor: '#00000000',
          statusBarContentColor: dark ? '#FFFFFF' : '#000000',
          navigationBarContentColor: dark ? '#FFFFFF' : '#000000'
        });
      } catch (error) { /* 忽略 */ }
      try { win.setWindowBackgroundColor(this.barBg); } catch (error) {
        hilog.warn(0, 'DSH_THEME', 'window background failed: %{public}s %{public}s', this.barBg, (error as Error).message);
      }
      this.updateInsets(win);
    }).catch(() => {});
  }

  // 避让区在布局切换后会晚一帧才更新，而且横竖屏切换也要重算：轮询里周期性
  // 采样，避免只在启动时取到 0 导致内容压到前摄/手势条下面。
  private syncInsets(): void {
    const context = this.context;
    if (!context) { return; }
    window.getLastWindow(context).then((win: window.Window) => {
      this.updateInsets(win);
    }).catch(() => {});
  }
  private updateInsets(win: window.Window): void {
    try {
      const system = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const cutout = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      const navigation = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      // 挖孔 Rect 不一定贴着屏幕顶边，只取 height 会把交界线压到前摄中心；
      // 取 top + height 再留 IMMERSIVE_TOP_GAP 的余量，交界线才会落在前摄下方。
      const cutoutBottom = avoidAreaBottom(cutout.topRect) + IMMERSIVE_TOP_GAP;
      const statusBottom = avoidAreaBottom(system.topRect);
      // 非沉浸式显示状态栏，内容要让到状态栏（含前摄）下方；
      // 沉浸式状态栏隐藏，只让开前摄挖孔；机型没有独立挖孔避让区时退回状态栏高度。
      const topPx = cutout.topRect.height > 0
        ? Math.max(cutoutBottom, this.systemBarsOn ? statusBottom : 0)
        : Math.max(statusBottom + IMMERSIVE_TOP_GAP, 0);
      // 底部两种模式一致：内容让开手势条/导航栏就好，栏区本身由应用背景铺满，
      // 不再多留一条系统白边。
      const bottomPx = Math.max(system.bottomRect.height, navigation.bottomRect.height);
      const top = px2vp(topPx);
      const bottom = px2vp(bottomPx);
      if (Number.isFinite(top) && Math.abs(top - this.insetTop) > 0.5) { this.insetTop = top; }
      if (Number.isFinite(bottom) && Math.abs(bottom - this.insetBottom) > 0.5) { this.insetBottom = bottom; }
    } catch (error) { /* 拿不到避让区就不留边 */ }
  }

  private boot(): void {
    if (this.busy) { return; }
    this.stopBrowserAgent('运行时重启，浏览器 Agent 已停止。');
    this.busy = true;
    this.failed = '';
    this.url = '';
    this.detail = '';
    this.webReady = false;
    this.browserControl.setVisible(false);
    if (this.readyTimer >= 0) { clearTimeout(this.readyTimer); this.readyTimer = -1; }
    if (this.absoluteTimer >= 0) { clearTimeout(this.absoluteTimer); this.absoluteTimer = -1; }
    this.status = '正在准备本地运行时';
    this.watchUnpacking();
    this.start(1);
  }
  // 解包状态由运行时告诉我们：它在 ensure() 里判断运行时目录是否完整。
  // 启动页每 300ms 跟一次，避免把「首次启动」的提示常驻在普通冷启动上。
  private watchUnpacking(): void {
    if (this.bootTimer >= 0) { return; }
    this.bootTimer = setInterval(() => {
      this.applyUnpacking(this.runtime?.isInstalling === true);
    }, 300);
  }
  // 解包会同步阻塞 UI 线程：回调在阻塞前先把状态交出来，轮询只作为兜底。
  private applyUnpacking(active: boolean): void {
    if (active === this.unpacking) { return; }
    this.unpacking = active;
    if (active) {
      this.status = '正在解包官方引擎、Python 与 Vim';
    } else if (this.status === '正在解包官方引擎、Python 与 Vim') {
      this.status = '正在启动本地运行时';
    }
  }
  private stopUnpackingWatch(): void {
    if (this.bootTimer >= 0) { clearInterval(this.bootTimer); this.bootTimer = -1; }
    if (this.unpacking) { this.unpacking = false; }
  }

  // 首个会话挂载 = 工作区恢复完成，输入框、右栏按钮和返回手势的 DOM 都已稳定。
  private markWebReady(): void {
    if (this.webReady) { return; }
    this.webReady = true;
    this.status = '';
    this.busy = false;
    if (this.readyTimer >= 0) { clearTimeout(this.readyTimer); this.readyTimer = -1; }
    if (this.absoluteTimer >= 0) { clearTimeout(this.absoluteTimer); this.absoluteTimer = -1; }
    this.settleQuarantine();
  }

  // 安全模式停用的插件：崩溃/看门狗导致的隔离自动恢复一次（恢复后重启引擎），
  // 插件自身加载失败导致的隔离则保留，并在 Web 上显示可手动恢复的提示条。
  private settleQuarantine(): void {
    const guard = this.guard;
    if (!guard || !guard.hasQuarantine()) {
      this.quarantineCount = 0;
      return;
    }
    if (!this.autoRestoreScheduled && guard.canAutoRestore()) {
      this.autoRestoreScheduled = true;
      guard.markAutoRestoreAttempted();
      const error = guard.restoreLastQuarantine();
      if (error === '') {
        // 插件目录已移回 profile，需要重启引擎才会重新加载。
        this.quarantineCount = 0;
        this.quarantineError = '';
        this.boot();
        return;
      }
      this.quarantineError = error;
    }
    this.quarantineCount = guard.quarantineCount();
  }

  // 提示条上的「恢复」：与启动页的恢复按钮走同一条路径。
  private restoreFromBanner(): void {
    const guard = this.guard;
    if (!guard) { return; }
    const error = guard.restoreLastQuarantine();
    if (error !== '') {
      this.quarantineError = error;
      this.quarantineCount = guard.quarantineCount();
      return;
    }
    this.quarantineCount = 0;
    this.quarantineError = '';
    this.boot();
  }

  // 兜底只从「官方前端已经挂载出首页」开始计时，不能从 URL 就绪时计时：
  // 冷启动时 Node/JITless + 插件加载本身可能超过 20 秒，过早放行会把
  // 「选择一个工作区开始」的半成品页露出来。首页出现后 60 秒仍无会话才放行。
  private armReadyFallback(): void {
    if (this.readyTimer >= 0) { return; }
    this.readyTimer = setTimeout(() => {
      this.readyTimer = -1;
      if (this.url !== '' && this.failed === '') { this.markWebReady(); }
    }, 60000);
  }

  // 极端兜底：Web 页面连首页都没挂出来（无 onErrorReceive 的挂死）时，
  // 不能让启动页无限盖住界面。只在 URL 就绪后计时，正常冷启动远早于此。
  private armAbsoluteFallback(): void {
    if (this.absoluteTimer >= 0) { return; }
    this.absoluteTimer = setTimeout(() => {
      this.absoluteTimer = -1;
      if (this.url !== '' && this.failed === '') { this.markWebReady(); }
    }, 120000);
  }

  // 运行时目录被改坏（少文件、半棵树）时的两种症状：模块找不到、启动器写不进去。
  // 这类错误重试同一个目录没有意义，必须整棵重解。
  private isRuntimeCorrupt(message: string): boolean {
    return /Cannot find (module|package)|ERR_MODULE_NOT_FOUND|failed to import|启动器写入失败|解包失败/.test(message);
  }

  // 用户插件（profile 层）造成的启动失败：模块解析不到、bundle 解析不到。
  private isPluginFailure(message: string): boolean {
    return /Cannot find (module|package)|ERR_MODULE_NOT_FOUND|failed to import|cannot resolve profile bundle/.test(message);
  }

  private async start(attempt: number): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.context = context;
      if (!this.runtime) { this.runtime = new NativeRuntime(context); }
      if (!this.guard) { this.guard = new PluginGuard(context); }
      const guard = this.guard;
      if (attempt === 1 && guard.lastBootFailed()) {
        // 上一次启动没走到界面：先按安全模式起，只留内置 bundle，
        // 让用户能进界面处理插件，而不是卡在启动失败。
        const outcome = guard.quarantine('上次启动未完成');
        if (outcome.moved.length > 0) {
          this.status = '安全模式：已临时停用 ' + outcome.moved.length.toString() + ' 个插件';
        }
        if (outcome.error !== '') {
          // 隔离有残留（目录不存在/移动失败/状态写不进）时提示出来，别静默。
          this.detail = (this.detail + '隔离插件：' + outcome.error + '\n').slice(-1200);
        }
      }
      guard.markBootStarted();
      const url = await this.runtime.startWebUI((text: string) => {
        this.status = '正在启动官方 Web 服务';
        this.detail = (this.detail + text).slice(-1200);
      }, (active: boolean) => {
        this.applyUnpacking(active);
      });
      guard.markBootSucceeded();
      this.status = '正在加载官方界面';
      this.url = url;
      this.webReady = false;
    this.browserControl.setVisible(false);
      this.armAbsoluteFallback();
      this.stopUnpackingWatch();
      // onPageEnd 不一定每次都触发；启动后先同步一次并挂上轮询，避免背景色一直停在启动回退色。
      this.syncBarsFromPage();
      if (this.barTimer < 0) {
        this.barTimer = setInterval(() => { this.syncBarsFromPage(); this.syncInsets(); }, 2000);
      }
      // 界面就绪后再处理保活，避免权限弹窗挡住首屏；之后每 3 秒跟一次插件设置。
      this.applyKeepAlive();
      this.applySystemBars();
      if (this.keepAliveTimer < 0) {
        this.keepAliveTimer = setInterval(() => {
          this.applyKeepAlive();
          this.applySystemBars();
        }, 3000);
      }
    } catch (error) {
      const message = (error as Error).message;
      if (attempt <= 2 && this.isPluginFailure(message) && this.guard) {
        // 先怀疑用户插件：隔离第三方 bundle 再试一次，运行时目录不动。
        this.status = '插件导致启动失败，正在停用用户插件后重试';
        this.detail = message;
        const outcome = this.guard.quarantine(message.slice(0, 200));
        if (outcome.moved.length > 0) {
          try {
            await this.start(3);
            return;
          } catch (second) {
            this.failed = '停用插件后仍失败：' + (second as Error).message;
            this.status = '启动失败';
            this.stopUnpackingWatch();
            this.busy = false;
            return;
          }
        }
        if (outcome.error !== '') {
          // 隔离没成功（例如包目录已损坏）：保留原始启动错误，同时说明为什么没重试。
          this.detail = (message + '\n隔离插件失败：' + outcome.error).slice(-1200);
        }
      }
      if (attempt === 1 && this.isRuntimeCorrupt(message)) {
        // 自动修复一次：删掉这棵运行时目录、重新解包。只做一次，避免死循环。
        this.status = '运行时目录损坏，正在重新解包';
        this.detail = message;
        try {
          await this.runtime?.repair((active: boolean) => {
            this.applyUnpacking(active);
          });
          await this.start(2);
          return;
        } catch (second) {
          this.failed = '自动重新解包后仍失败：' + (second as Error).message;
          this.status = '启动失败';
          this.stopUnpackingWatch();
          this.busy = false;
          return;
        }
      }
      this.failed = message;
      this.status = '启动失败';
      this.stopUnpackingWatch();
      this.busy = false;
    }
  }

  // 界面上的「重新解包运行时」：用户手动触发一次整棵重建。
  private async repairRuntime(): Promise<void> {
    if (this.busy) { return; }
    this.stopBrowserAgent('运行时修复，浏览器 Agent 已停止。');
    this.busy = true;
    this.failed = '';
    this.url = '';
    this.detail = '';
    this.webReady = false;
    this.browserControl.setVisible(false);
    if (this.readyTimer >= 0) { clearTimeout(this.readyTimer); this.readyTimer = -1; }
    if (this.absoluteTimer >= 0) { clearTimeout(this.absoluteTimer); this.absoluteTimer = -1; }
    this.status = '正在删除并重新解包运行时';
    this.watchUnpacking();
    try {
      await this.runtime?.repair((active: boolean) => {
        this.applyUnpacking(active);
      });
      await this.start(2);
    } catch (error) {
      this.failed = (error as Error).message;
      this.status = '启动失败';
      this.stopUnpackingWatch();
      this.busy = false;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.url !== '') {
        // 沉浸式下系统栏是隐藏的，但挖孔/底部手势条仍会盖住页面：这里按
        // 避让区给 Web 让出上下两条（inset 为 0 时就是原来的满屏）。
        Column() {
        Web({ src: this.url, controller: this.controller })
          // 不开应用内新窗口：window.open 和 <a target="_blank"> 都由文档起点注入的
          // BRIDGE_DOCUMENT_SCRIPT 拦下并转给系统浏览器，内核不会拿到新窗口请求。
          .multiWindowAccess(false)
          .javaScriptAccess(true)
          // 下载走 javaScriptProxy：页面把分片交给 Index，落盘后再回路径。
          // permission 只放行运行时本地 origin（端口是动态的），第三方页面即使
          // 被加载也拿不到 dshNative。
          .javaScriptProxy({
            object: this.downloadSink,
            name: 'dshNative',
            methodList: ['put'],
            controller: this.controller,
            permission: this.proxyPermission()
          })
          // 必须在页面脚本之前装好附件上传钩子与外链/下载桥，否则 FileUploadRuntime
          // 已经选了 Worker 通道，而桌面外壳的扩展点也已经按「不存在」处理过了。
          // scriptRules 只给本地 origin，不再用 '*'：预览/内置浏览器里的第三方页面
          // 不应拿到壳层注入的桥与 nonce。
          .javaScriptOnDocumentStart([
            { script: RESOURCE_URL_DOCUMENT_SCRIPT, scriptRules: this.documentScriptRules() },
            { script: UPLOAD_DOCUMENT_SCRIPT, scriptRules: this.documentScriptRules() },
            { script: this.bridgeDocumentScript(), scriptRules: this.documentScriptRules() }
          ])
          .domStorageAccess(true)
          // 页面不需要 file:// 与数据库存储；关掉后即使导航/注入被绕过也拿不到
          // 应用沙箱文件，减少 WebView 能力面。
          .databaseAccess(false)
          .fileAccess(false)
          // 关闭双指缩放：界面按视口宽度布局，缩放会把终端/侧栏的几何算乱。
          .zoomAccess(false)
          .imageAccess(true)
          .onlineImageAccess(true)
          // 跟随系统深浅色：页面里的 prefers-color-scheme 才跟手系统设置；
          // forceDarkAccess 必须关掉，否则 ArkWeb 会把页面再反色一遍。
          .darkMode(WebDarkMode.Auto)
          .forceDarkAccess(false)
          .width('100%')
          .height('100%')
          .backgroundColor(this.barBg)
          .onPageEnd(() => {
            // 静态页面加载完不等于界面可用：继续压着启动页，等 startUiWatch
            // 看到首个会话挂载后再放行。
            if (!this.webReady) { this.status = '正在准备界面'; }
            this.stopUnpackingWatch();
            this.busy = false;
            this.syncBarsFromPage();
            this.installPopupBridge();
            if (this.barTimer < 0) {
              this.barTimer = setInterval(() => { this.syncBarsFromPage(); this.syncInsets(); }, 2000);
            }
          })
          // 页面里的终端插件用 console.log('DSH_TERM:<nonce>:' + json) 上报 tab 的状态。
          .onConsole((event: OnConsoleEvent) => {
            try {
              if (this.isLocalConsoleSource(event.message.getSourceId())) {
                this.onTermBridge(event.message.getMessage());
              }
            } catch (error) { /* 控制台消息不是桥消息 */ }
            return false;
          })
          // 主框架只允许留在本地 Web 服务：任何站外 http(s) 跳转都交给系统浏览器，
          // data:/blob:/javascript:/file: 等其它 scheme 一律直接拦截，避免 Web 组件
          // 显示一个加载不出来的白页或执行 app 侧不期望的导航。
          .onLoadIntercept((event: OnLoadInterceptEvent) => {
            try {
              const request = event.data;
              if (!request.isMainFrame()) { return false; }
              const target = request.getRequestUrl();
              if (target === '') { return true; }
              let protocol = '';
              try {
                const parsed = new url.URL(target);
                protocol = parsed.protocol.toLowerCase().replace(/:$/, '');
              } catch (error) { return true; }
              if (protocol !== 'http' && protocol !== 'https') { return true; }
              if (this.isLocalUrl(target)) { return false; }
              this.openExternal(target);
              return true;
            } catch (error) { return true; }
          })
          // http(s) 下载不经内核落盘：交给页面侧的保存桥，由壳层弹系统保存框。
          .onDownloadStart((event: OnDownloadStartEvent) => {
            try {
              if (!/^https?:/i.test(event.url)) { return; }
              const name = this.nameFromUrl(event.url);
              this.controller.runJavaScript(
                'window.__dshSaveUrl(' + JSON.stringify(event.url) + ',' + JSON.stringify(name) + ')'
              ).catch(() => {});
            } catch (error) { /* Web 未挂载 */ }
          })
          .onErrorReceive((event: OnErrorReceiveEvent) => {
            if (event && event.error && event.error.getErrorInfo()) {
              this.failed = event.error.getErrorInfo();
            }
          })
        }
        .width('100%')
        .height('100%')
        .padding({ top: this.insetTop, bottom: this.insetBottom })
      }
      if (this.url === '' || !this.webReady) {
        Column({ space: 16 }) {
          Image($r('app.media.app_icon'))
            .width(88)
            .height(88)
            .borderRadius(22)
            .objectFit(ImageFit.Cover)
            .shadow({ radius: 20, color: '#33000000', offsetY: 6 })
          Column({ space: 6 }) {
            Text('Pocket Harness')
              .fontSize(28)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.barDark ? '#DCEFE2' : '#1F3D2E')
            Text('DeepSeek Harness · 鸿蒙原生')
              .fontSize(12)
              .fontColor(this.barDark ? '#8FA396' : '#6B8474')
          }
          Text(this.status)
            .fontSize(15)
            .fontColor(this.barDark ? '#9FB8A8' : '#4C6B58')
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
          if (this.failed !== '') {
            Text(this.failed)
              .fontSize(13)
              .fontColor(this.barDark ? '#F0A0A0' : '#8C2F2F')
              .textAlign(TextAlign.Center)
              .padding({ left: 24, right: 24 })
              .maxLines(8)
            Row({ space: 12 }) {
              Button('重试')
                .fontSize(15)
                .backgroundColor('#1F5D3A')
                .onClick(() => { this.boot(); })
              Button('重新解包运行时')
                .fontSize(15)
                .backgroundColor('#4C6B58')
                .onClick(() => { this.repairRuntime(); })
              if (this.guard !== undefined && this.guard.hasQuarantine()) {
                Button('恢复上次插件配置')
                  .fontSize(15)
                  .backgroundColor('#6B5B4C')
                  .onClick(() => {
                    const error = this.guard !== undefined ? this.guard.restoreLastQuarantine() : '插件的守门人未初始化';
                    // 恢复没完全成功时保留隔离记录并把原因显示出来，不重启引擎。
                    if (error !== '') {
                      this.failed = error;
                      this.status = '恢复插件失败';
                      return;
                    }
                    this.failed = '';
                    this.boot();
                  })
              }
            }
          } else {
            LoadingProgress()
              .width(48)
              .height(48)
              .color(this.barDark ? '#7FC79B' : '#1F5D3A')
            // 只有真的在解包时才说「首次启动」；普通冷启动只是等 Web 服务起来。
            Text(this.unpacking
              ? '首次启动会把官方引擎解包到应用沙箱，约 1–2 分钟，请保持应用在前台。'
              : (this.url === '' ? '正在启动本地运行时…' : '正在恢复上次会话与工作区…'))
              .fontSize(12)
              .fontColor(this.barDark ? '#8FA396' : '#7A8F81')
              .textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
          }
          if (this.detail !== '') {
            Text(this.detail)
              .fontSize(10)
              .fontColor(this.barDark ? '#7E8F84' : '#8FA396')
              .maxLines(6)
              .textAlign(TextAlign.Start)
              .padding({ left: 20, right: 20 })
          }
        }
        .width('100%')
        .height('100%')
        .padding({ top: this.insetTop, bottom: this.insetBottom })
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.barBg)
        // 启动页必须真正吃掉触摸：否则用户仍能点到下面半就绪的 Web UI。
        .hitTestBehavior(HitTestMode.Block)
      }
      // 安全模式仍有隔离插件时，在 Web 上压一条提示：主界面已经能用，但用户
      // 需要知道哪些插件被停用，并能一键恢复。
      if (this.webReady && this.quarantineCount > 0) {
        Column() {
          Column({ space: 4 }) {
            Row({ space: 10 }) {
              Text('安全模式：已停用 ' + this.quarantineCount.toString() + ' 个插件')
                .fontSize(12)
                .fontColor(this.barDark ? '#F0D9B5' : '#5A421F')
                .layoutWeight(1)
              Button('恢复插件')
                .fontSize(12)
                .height(28)
                .backgroundColor('#6B5B4C')
                .onClick(() => { this.restoreFromBanner(); })
            }
            if (this.quarantineError !== '') {
              Text(this.quarantineError)
                .fontSize(10)
                .fontColor(this.barDark ? '#F0A0A0' : '#8C2F2F')
                .maxLines(3)
            }
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor(this.barDark ? '#E62A2A2E' : '#E6FFF6E0')
          .borderRadius(10)
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
        .position({ x: 0, y: this.insetTop + 10 })
      }
      if (this.showBrowser) {
        BrowserView({
          control: this.browserControl,
          dark: this.barDark,
          isHostVisible: () => this.browserAvailable(),
          stageLeft: this.browserClipLeft(),
          // 与终端相同：页面坐标以 Web 内容区为原点，沉浸式时 Web 被顶部避让区
          // 下推了 insetTop，浏览器浮层要跟着加同样的偏移。
          stageTop: this.browserClipTop() + this.insetTop,
          stageWidth: this.browserActuallyVisible() ? this.browserClipWidth() : 400,
          stageHeight: this.browserActuallyVisible() ? this.browserClipHeight() : 600,
          visible: this.browserActuallyVisible(),
          active: this.browserAvailable(),
          agentConnected: this.browserAgentConnected,
          agentMessage: this.browserAgentMessage,
          onStartAgent: () => { this.startBrowserAgent(); },
          onStopAgent: () => { this.stopBrowserAgent('浏览器 Agent 已停止。'); },
          onNavigationFailure: () => {
            if (this.browserBridge) { this.stopBrowserAgent('主页面加载失败，浏览器 Agent 已停止。'); }
          },
          onConfirmPage: () => {
            const confirmed = this.browserBridge?.confirmCurrentPage() === true;
            this.browserAgentMessage = confirmed ?
              '已确认当前页面；后续每次操作仍需单独同意。页面仍可能变化。' :
              '无法恢复：请等待导航开始及页面结束，并确认浏览器和当前会话仍可见。';
          },
          onClose: () => { this.closeBrowser(); }
        })
      }
      BrowserConsentView({ control: this.browserConsent })
      // 右侧栏 tab 的终端画面：只铺在页面报上来的矩形上，侧栏和 dock 仍是页面的。
      if (this.showTerminal && this.termWidth > 0 && this.termHeight > 0) {
        TerminalView({
          runtime: this.runtime,
          stageLeft: this.termLeft,
          // 页面坐标的原点在 Web 内容区；沉浸式时 Web 被顶部避让区下推了
          // insetTop，终端浮层要跟着加同样的偏移。
          stageTop: this.termTop + this.insetTop,
          stageWidth: this.termWidth,
          stageHeight: this.termHeight,
          visible: this.termVisible,
          workspaceCwd: this.termCwd,
          onClose: () => { this.showTerminal = false; this.termVisible = false; this.termOwner = ''; }
        })
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_old: Area, area: Area) => {
      const width = Number(area.width);
      const height = Number(area.height);
      this.stageWidth = Number.isFinite(width) ? Math.max(0, width) : 0;
      this.stageHeight = Number.isFinite(height) ? Math.max(0, height) : 0;
      this.browserControl.setVisible(this.browserAvailable());
    })
    // 两种模式都全屏：系统栏区域由外层背景铺满，颜色跟 Web 主题同步；
    // 内容自己的留白由 insetTop/insetBottom 负责，不能用安全区再挤一次。
    .backgroundColor(this.barBg)
    .expandSafeArea(
      [SafeAreaType.SYSTEM, SafeAreaType.KEYBOARD],
      [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
