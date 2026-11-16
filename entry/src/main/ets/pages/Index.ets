import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { window, mediaquery } from '@kit.ArkUI';
import { TerminalView } from './Terminal';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NativeRuntime } from '../platform/NativeRuntime';
import { BackgroundKeepAlive } from '../platform/BackgroundKeepAlive';
import { PluginGuard } from '../platform/PluginGuard';

// 页面里的终端入口把 location.hash 改成 #dshterm，原生轮询 controller.getUrl() 读取，
// 不依赖 javascriptProxy 注册，避免桥上偶发失效。

// 界面就是官方 Web GUI：设备内跑 `dsh --profile web`，Web 组件加载它打印的
// http://127.0.0.1:<port>。这里只保留启动/等待/失败三种状态，不再自绘会话界面。
@Entry
@Component
struct Index {
  @State private url: string = '';
  @State private showTerminal: boolean = false;
  // 右侧栏终端 tab 的矩形（页面 CSS 像素 == vp），由页面的桥消息更新。
  @State private termLeft: number = 0;
  @State private termTop: number = 0;
  @State private termWidth: number = 0;
  @State private termHeight: number = 0;
  @State private termVisible: boolean = false;
  // 当前 DSH 会话的工作目录，由页面插件从宿主 API 解析后下发；终端用它作为 cwd。
  @State private termCwd: string = '';
  @State private status: string = '正在准备原生运行时';
  @State private detail: string = '';
  @State private failed: string = '';
  @State private busy: boolean = false;
  // 只有真的在解包时才提示「首次启动需要 1–2 分钟」；普通冷启动不该看到这句。
  @State private unpacking: boolean = false;
  private bootTimer: number = -1;
  private runtime?: NativeRuntime;
  private guard?: PluginGuard;
  private keepAlive: BackgroundKeepAlive = new BackgroundKeepAlive();
  private context?: common.UIAbilityContext;
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
  @State private insetTop: number = 0;
  @State private barBg: string = '';

  aboutToAppear(): void {
    try { this.context = this.getUIContext().getHostContext() as common.UIAbilityContext; } catch (error) { /* 取不到上下文时延后处理 */ }
    this.followSystemBars();
    this.startUiWatch();
    this.boot();
  }

  // 返回手势需要同步判断页面上的浮层，runJavaScript 是异步的：这里每 500ms
  // 采样一次页面状态，onBackPress 里按优先级动作。
  private startUiWatch(): void {
    if (this.uiTimer >= 0) { return; }
    const script =
      "(function(){try{" +
      "var d=document.querySelector('[role=dialog][aria-label=\"导航\"]');" +
      "var nav=!!d&&getComputedStyle(d).visibility!=='hidden'&&d.getBoundingClientRect().x>=0;" +
      "var other=document.querySelector('[role=dialog]:not([aria-label=\"导航\"])');" +
      "var menu=!!document.querySelector('[role=menu]');" +
      "var right=!!document.querySelector('[aria-label=\"收起右侧边栏\"]');" +
      "return JSON.stringify({nav:nav,dialog:!!other,menu:menu,right:right});" +
      "}catch(e){return '{}';}})()";
    this.uiTimer = setInterval(() => {
      if (this.url === '') { return; }
      try {
        this.controller.runJavaScript(script).then((result: string) => {
          try {
            let text = String(result);
            if (text.startsWith('"')) { text = JSON.parse(text) as string; }
            const state = JSON.parse(text) as Record<string, boolean>;
            this.webNav = state['nav'] === true;
            this.webDialog = state['dialog'] === true;
            this.webMenu = state['menu'] === true;
            this.webRight = state['right'] === true;
          } catch (error) { /* 解析失败时保留上一次状态 */ }
        }).catch(() => {});
      } catch (error) { /* Web 未挂载 */ }
    }, 500);
  }

  private pressEscape(): void {
    try {
      this.controller.runJavaScript(
        "(function(){try{document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',code:'Escape',bubbles:true}));}catch(e){}})()"
      ).catch(() => {});
    } catch (error) { /* Web 未挂载 */ }
  }

  private clickSidebarToggle(): void {
    try {
      this.controller.runJavaScript(
        "(function(){try{var es=[].slice.call(document.querySelectorAll('[aria-label=\"打开侧边栏\"]'));" +
        "for(var i=0;i<es.length;i++){if(es[i].getBoundingClientRect().x>=0){es[i].click();return;}}}catch(e){}})()"
      ).catch(() => {});
    } catch (error) { /* Web 未挂载 */ }
  }

  // 菜单没有 Escape 处理，点它自己的触发按钮（aria-expanded=true）才会收起。
  private closeMenu(): void {
    try {
      this.controller.runJavaScript(
        "(function(){try{var es=[].slice.call(document.querySelectorAll('[aria-haspopup=menu][aria-expanded=true]'));" +
        "for(var i=0;i<es.length;i++){if(es[i].getBoundingClientRect().x>=0){es[i].click();return;}}}catch(e){}})()"
      ).catch(() => {});
    } catch (error) { /* Web 未挂载 */ }
  }

  aboutToDisappear(): void {
    if (this.barTimer >= 0) { clearInterval(this.barTimer); this.barTimer = -1; }
    if (this.keepAliveTimer >= 0) { clearInterval(this.keepAliveTimer); this.keepAliveTimer = -1; }
    if (this.uiTimer >= 0) { clearInterval(this.uiTimer); this.uiTimer = -1; }
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
        "(function(){try{if(window.__dshCollapseRightSidebar)return window.__dshCollapseRightSidebar();}catch(e){}" +
        "var es=[].slice.call(document.querySelectorAll('[aria-label]'));" +
        "for(var i=0;i<es.length;i++){var a=es[i].getAttribute('aria-label')||'';" +
        "if(/^(collapse|收起)\\b.*(right sidebar|右侧边栏)$/i.test(a)){es[i].click();return true;}}" +
        "return false;})()"
      ).catch(() => {});
    } catch (error) { /* Web 未挂载 */ }
  }

  onBackPress(): boolean {
    // 按浮层优先级逐层关闭：菜单 → 对话框（设置）→ 右侧栏/终端 → 左侧抽屉 →
    // Web 历史；都没有时交回系统（退到后台/退出）。
    if (this.webMenu) { this.closeMenu(); return true; }
    if (this.webDialog) { this.pressEscape(); return true; }
    if (this.termVisible || this.webRight) { this.collapseRightSidebar(); return true; }
    if (this.webNav) { this.clickSidebarToggle(); return true; }
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
        "(function(){var d=document.documentElement,b=document.body;" +
        "var pick=function(c){return c&&c!=='transparent'&&c.indexOf('rgba(0, 0, 0, 0)')<0&&c.indexOf('rgba(0,0,0,0)')<0;};" +
        "var cands=[getComputedStyle(b).backgroundColor,getComputedStyle(d).backgroundColor," +
        "getComputedStyle(d).getPropertyValue('--dsw-alias-bg-base').trim()," +
        "getComputedStyle(d).getPropertyValue('--dsw-alias-bg-l1').trim()];" +
        "var bg='';for(var i=0;i<cands.length;i++){if(pick(cands[i])){bg=cands[i];break;}}" +
        "return JSON.stringify({dark:window.matchMedia('(prefers-color-scheme: dark)').matches,bg:bg});})()";
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

  // 页面里的 window.open 在 ArkWeb 里会走「新窗口」通道：没有 onWindowNew 处理器时
  // 渲染进程会被阻塞，表现就是点登录后整页黑屏。这里不给页面开新窗口的能力，并
  // 接管 window.open，把外部链接交给系统浏览器。
  private installPopupBridge(): void {
    const script =
      "(function(){if(window.__dshPopupBridge){return;}window.__dshPopupBridge=true;" +
      "var send=function(u){try{console.log('DSH_TERM:'+JSON.stringify({op:'openExternal',url:String(u)}));}catch(e){}};" +
      "window.open=function(url){" +
      "var stub={closed:false,opener:null,focus:function(){},close:function(){stub.closed=true;}," +
      "location:{replace:function(u){send(u);},assign:function(u){send(u);}}};" +
      "try{Object.defineProperty(stub.location,'href',{get:function(){return url;},set:function(u){send(u);},configurable:true});}catch(e){}" +
      "if(url&&url!=='about:blank'){send(url);}" +
      "return stub;};})()";
    try { this.controller.runJavaScript(script).catch(() => {}); } catch (error) { /* Web 未挂载 */ }
  }
  private openExternal(url: string): void {
    if (!/^https?:\/\//i.test(url)) { return; }
    const context = this.context;
    if (!context) { return; }
    try { context.openLink(url).catch(() => {}); } catch (error) { /* 没有可用浏览器 */ }
  }
  // 页面 → 壳层：DSH 客户端插件把终端 tab 的 open/bounds/visible/close 以
  // `console.log('DSH_TERM:' + json)` 发过来，没有 JS 代理也能用。
  private onTermBridge(text: string): void {
    if (text.indexOf('DSH_TERM:') !== 0) { return; }
    try {
      const message = JSON.parse(text.slice(9)) as Record<string, Object>;
      const op = message['op'] as string;
      if (op === 'open') {
        this.showTerminal = true;
        this.termVisible = false;
        const cwd = message['cwd'] as string;
        if (typeof cwd === 'string' && cwd !== '') { this.termCwd = cwd; }
      } else if (op === 'cwd') {
        // 页面从宿主 API 拿到当前会话的工作目录后补发过来，终端跟随它。
        const cwd = message['cwd'] as string;
        if (typeof cwd === 'string' && cwd !== '') { this.termCwd = cwd; }
      } else if (op === 'bounds') {
        const left = Number(message['left']);
        const top = Number(message['top']);
        const width = Number(message['width']);
        const height = Number(message['height']);
        if (!Number.isFinite(left) || !Number.isFinite(top) ||
          !Number.isFinite(width) || !Number.isFinite(height)) { return; }
        this.termLeft = left;
        this.termTop = top;
        this.termWidth = Math.max(1, width);
        this.termHeight = Math.max(1, height);
        this.termVisible = message['visible'] === true && this.termWidth > 1 && this.termHeight > 1;
        this.showTerminal = true;
      } else if (op === 'visible') {
        this.termVisible = message['visible'] === true;
      } else if (op === 'focus') {
        // 页面要求聚焦终端输入框时再弹键盘：终端 tab 打开本身不抢焦点，
        // 否则横屏下键盘一上来就把仅剩的几行终端压没了。
        try { this.getUIContext().getFocusController().requestFocus('term-input'); } catch (error) { /* 未挂载 */ }
      } else if (op === 'openExternal') {
        const url = message['url'] as string;
        if (typeof url === 'string') { this.openExternal(url); }
      } else if (op === 'close') {
        this.showTerminal = false;
      }
    } catch (error) { /* 不是桥消息，忽略 */ }
  }

  private applyBars(dark: boolean, background: string): void {
    const fallback = dark ? '#101113' : '#F7F7F0';
    const normalized = this.normalizeColor(background);
    this.barDark = dark;
    this.barBg = normalized !== '' ? normalized : fallback;
    const context = this.context;
    if (!context) { return; }
    window.getLastWindow(context).then((win: window.Window) => {
      // 沉浸式（EntryAbility 里已设全屏 + 透明栏）：这里只同步栏区图标颜色、
      // 页面背景色，并把内容按避让区让开；栏区露出的就是页面背景。
      try {
        win.setWindowSystemBarProperties({
          statusBarContentColor: dark ? '#FFFFFF' : '#000000',
          navigationBarContentColor: dark ? '#FFFFFF' : '#000000'
        });
      } catch (error) { /* 忽略 */ }
      try { win.setWindowBackgroundColor(this.barBg); } catch (error) {
        hilog.warn(0, 'DSH_THEME', 'window background failed: %{public}s %{public}s', this.barBg, (error as Error).message);
      }
      try {
        const system = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const cutout = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
        // 系统栏已隐藏，但状态栏/挖孔在系统侧仍有高度；取较大值让顶部 UI 让开前摄。
        this.insetTop = px2vp(Math.max(system.topRect.height, cutout.topRect.height));
      } catch (error) { /* 拿不到避让区就不留边 */ }
    }).catch(() => {});
  }

  private boot(): void {
    if (this.busy) { return; }
    this.busy = true;
    this.failed = '';
    this.url = '';
    this.detail = '';
    this.status = '正在准备本地运行时';
    this.watchUnpacking();
    this.start(1);
  }
  // 解包状态由运行时告诉我们：它在 ensure() 里判断运行时目录是否完整。
  // 启动页每 300ms 跟一次，避免把「首次启动」的提示常驻在普通冷启动上。
  private watchUnpacking(): void {
    if (this.bootTimer >= 0) { return; }
    this.bootTimer = setInterval(() => {
      const now = this.runtime?.isInstalling === true;
      if (now !== this.unpacking) {
        this.unpacking = now;
        if (now) { this.status = '正在解包官方引擎与 npm'; }
      }
    }, 300);
  }
  private stopUnpackingWatch(): void {
    if (this.bootTimer >= 0) { clearInterval(this.bootTimer); this.bootTimer = -1; }
    if (this.unpacking) { this.unpacking = false; }
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
        const removed = guard.quarantine('上次启动未完成');
        if (removed.length > 0) {
          this.status = '安全模式：已临时停用 ' + removed.length.toString() + ' 个插件';
        }
      }
      guard.markBootStarted();
      const url = await this.runtime.startWebUI((text: string) => {
        this.status = '正在启动官方 Web 服务';
        this.detail = (this.detail + text).slice(-1200);
      });
      guard.markBootSucceeded();
      this.status = '正在加载官方界面';
      this.url = url;
      this.stopUnpackingWatch();
      // onPageEnd 不一定每次都触发；启动后先同步一次并挂上轮询，避免背景色一直停在启动回退色。
      this.syncBarsFromPage();
      if (this.barTimer < 0) {
        this.barTimer = setInterval(() => { this.syncBarsFromPage(); }, 2000);
      }
      // 界面就绪后再处理保活，避免权限弹窗挡住首屏；之后每 3 秒跟一次插件设置。
      this.applyKeepAlive();
      if (this.keepAliveTimer < 0) {
        this.keepAliveTimer = setInterval(() => { this.applyKeepAlive(); }, 3000);
      }
    } catch (error) {
      const message = (error as Error).message;
      if (attempt <= 2 && this.isPluginFailure(message) && this.guard) {
        // 先怀疑用户插件：隔离第三方 bundle 再试一次，运行时目录不动。
        this.status = '插件导致启动失败，正在停用用户插件后重试';
        this.detail = message;
        const removed = this.guard.quarantine(message.slice(0, 200));
        if (removed.length > 0) {
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
      }
      if (attempt === 1 && this.isRuntimeCorrupt(message)) {
        // 自动修复一次：删掉这棵运行时目录、重新解包。只做一次，避免死循环。
        this.status = '运行时目录损坏，正在重新解包';
        this.detail = message;
        try {
          await this.runtime?.repair();
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
    this.busy = true;
    this.failed = '';
    this.url = '';
    this.detail = '';
    this.status = '正在删除并重新解包运行时';
    this.watchUnpacking();
    try {
      await this.runtime?.repair();
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
        Web({ src: this.url, controller: this.controller })
          // 不开应用内新窗口：window.open 一律由 installPopupBridge 接管并转给系统浏览器，
          // 否则 ArkWeb 会因为缺少 onWindowNew 处理而阻塞渲染进程（黑屏）。
          .multiWindowAccess(false)
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .databaseAccess(true)
          .fileAccess(true)
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
            this.status = '';
            this.stopUnpackingWatch();
            this.busy = false;
            this.syncBarsFromPage();
            this.installPopupBridge();
            if (this.barTimer < 0) {
              this.barTimer = setInterval(() => { this.syncBarsFromPage(); }, 2000);
            }
          })
          // 页面里的终端插件用 console.log('DSH_TERM:' + json) 上报 tab 的状态。
          .onConsole((event: OnConsoleEvent) => {
            try {
              this.onTermBridge(event.message.getMessage());
            } catch (error) { /* 控制台消息不是桥消息 */ }
            return false;
          })
          .onErrorReceive((event: OnErrorReceiveEvent) => {
            if (event && event.error && event.error.getErrorInfo()) {
              this.failed = event.error.getErrorInfo();
            }
          })
      } else {
        Column({ space: 16 }) {          Text('Pocket Harness')
            .fontSize(28)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.barDark ? '#DCEFE2' : '#1F3D2E')
          Text(this.status)
            .fontSize(15)
            .fontColor(this.barDark ? '#9FB8A8' : '#4C6B58')
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
                    this.guard?.restoreLastQuarantine();
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
              ? '首次启动要把官方引擎解包到应用沙箱，需要一到两分钟。'
              : '正在启动本地运行时…')
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
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.barBg)
      }
      // 右侧栏 tab 的终端画面：只铺在页面报上来的矩形上，侧栏和 dock 仍是页面的。
      if (this.showTerminal && this.termWidth > 0 && this.termHeight > 0) {
        TerminalView({
          runtime: this.runtime,
          stageLeft: this.termLeft,
          stageTop: this.termTop,
          stageWidth: this.termWidth,
          stageHeight: this.termHeight,
          visible: this.termVisible,
          workspaceCwd: this.termCwd,
          onClose: () => { this.showTerminal = false; }
        })
      }
    }
    .width('100%')
    .height('100%')
    // 状态栏/导航栏现在是透明的，这两条留白由外层背景补上，颜色跟 Web 主题同步。
    .backgroundColor(this.barBg)
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.KEYBOARD], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
