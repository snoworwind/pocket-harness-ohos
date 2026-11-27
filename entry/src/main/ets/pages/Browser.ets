import { webview } from '@kit.ArkWeb';
import { url } from '@kit.ArkTS';
import { BROWSER_CLICK_INDEX_PLACEHOLDER, BROWSER_CLICK_SCRIPT_TEMPLATE, BROWSER_OBSERVE_SCRIPT } from './BrowserObserveScript';

// 仅供宿主持有；调用者负责先完成用户授权。代数随实例、可见性和导航变化失效。
export interface BrowserObservation {
  generation: number;
  title: string;
  url: string;
}

export class BrowserControl {
  private generation: number = 0;
  private attached: boolean = false;
  private visible: boolean = false;
  private pendingNavigation: boolean = false;
  private beginUrl: string = '';
  private endedGeneration: number = -1;
  private isHostVisible: () => boolean = () => false;
  private openPage: (target: string) => boolean = () => false;
  private readPage: () => BrowserObservation | null = () => null;
  private runSnapshot: () => Promise<string> = async () => { throw new Error('Browser unavailable'); };
  private scrollPage: (offset: number) => void = () => { throw new Error('Browser unavailable'); };
  private runClick: (ref: string) => Promise<string> = async () => { throw new Error('Browser unavailable'); };

  attach(isHostVisible: () => boolean, openPage: (target: string) => boolean,
    readPage: () => BrowserObservation | null,
    runSnapshot: () => Promise<string> = async () => { throw new Error('Browser unavailable'); },
    scrollPage: (offset: number) => void = () => { throw new Error('Browser unavailable'); },
    runClick: (ref: string) => Promise<string> = async () => { throw new Error('Browser unavailable'); }): void {
    this.generation++;
    this.pendingNavigation = false;
    this.beginUrl = '';
    this.endedGeneration = -1;
    this.attached = true;
    this.visible = false;
    this.isHostVisible = isHostVisible;
    this.openPage = openPage;
    this.readPage = readPage;
    this.runSnapshot = runSnapshot;
    this.scrollPage = scrollPage;
    this.runClick = runClick;
  }

  detach(): void {
    this.generation++;
    this.pendingNavigation = false;
    this.beginUrl = '';
    this.endedGeneration = -1;
    this.attached = false;
    this.visible = false;
    this.isHostVisible = () => false;
    this.openPage = () => false;
    this.readPage = () => null;
    this.runSnapshot = async () => { throw new Error('Browser unavailable'); };
    this.scrollPage = () => { throw new Error('Browser unavailable'); };
    this.runClick = async () => { throw new Error('Browser unavailable'); };
  }

  setVisible(visible: boolean): void {
    if (this.visible !== visible) {
      this.generation++;
      this.visible = visible;
      this.pendingNavigation = false;
      this.beginUrl = '';
      this.endedGeneration = -1;
    }
  }

  navigationChanged(): void {
    this.generation++;
    this.beginUrl = '';
    this.endedGeneration = -1;
  }

  // Arm immediately before submitting an approved open. Manual navigation and
  // every subsequent main-frame begin invalidate previously observed ends.
  armRebind(generation: number): boolean {
    if (this.currentGeneration() !== generation) { return false; }
    this.pendingNavigation = true;
    this.beginUrl = '';
    this.endedGeneration = -1;
    return true;
  }

  pageBegin(pageUrl: string): void {
    this.navigationChanged();
    if (this.pendingNavigation && this.currentGeneration() !== null) { this.beginUrl = pageUrl; }
  }

  pageEnd(pageUrl: string): void {
    if (this.pendingNavigation && this.beginUrl !== '' && this.beginUrl === pageUrl &&
      this.currentGeneration() !== null) { this.endedGeneration = this.generation; }
  }

  rebindPage(): BrowserObservation | null {
    const generation = this.currentGeneration();
    if (!this.pendingNavigation || generation === null || this.endedGeneration !== generation) { return null; }
    const page = this.observe(generation);
    if (page === null || page.url !== this.beginUrl || !/^https?:\/\//i.test(page.url) ||
      this.endedGeneration !== generation || this.currentGeneration() !== generation) { return null; }
    return page;
  }

  consumeRebind(): void {
    this.pendingNavigation = false;
    this.beginUrl = '';
    this.endedGeneration = -1;
  }

  currentGeneration(): number | null {
    return this.attached && this.visible && this.isHostVisible() ? this.generation : null;
  }

  // 必须传入授权时取得的代数；导航开始即撤销该代数。
  open(generation: number, target: string): boolean {
    if (this.currentGeneration() !== generation) { return false; }
    return this.openPage(target);
  }

  observe(generation: number): BrowserObservation | null {
    if (this.currentGeneration() !== generation) { return null; }
    const result = this.readPage();
    if (this.currentGeneration() !== generation || result === null) { return null; }
    result.generation = generation;
    return result;
  }

  scroll(generation: number, direction: string): void {
    if (this.currentGeneration() !== generation || (direction !== 'up' && direction !== 'down')) {
      throw new Error('Browser binding changed');
    }
    this.scrollPage(direction === 'up' ? -400 : 400);
  }

  // The caller must have consumed native approval and must validate the session
  // and URL/title again after awaiting. No retry on errors or binding changes.
  async snapshot(generation: number): Promise<string> {
    if (this.currentGeneration() !== generation) { throw new Error('Browser binding changed'); }
    const result = await this.runSnapshot();
    if (this.currentGeneration() !== generation) { throw new Error('Browser binding changed'); }
    return result;
  }

  // A reference is only meaningful for the snapshot that produced it and may be
  // stale. The program is fixed; only a bounded integer index is substituted.
  // A returned 'clicked' means the click was dispatched, not that the page
  // reacted, navigated or stayed stable.
  async click(generation: number, ref: string): Promise<string> {
    if (this.currentGeneration() !== generation) { throw new Error('Browser binding changed'); }
    if (typeof ref !== 'string' || !/^e\d{1,3}$/.test(ref)) { throw new Error('Invalid element reference'); }
    const index = Number(ref.slice(1));
    if (!Number.isSafeInteger(index) || index < 0 || index >= 80) { throw new Error('Invalid element reference'); }
    const result = await this.runClick(ref);
    if (this.currentGeneration() !== generation) { throw new Error('Browser binding changed'); }
    return result;
  }
}

// 独立 Web 实例：不注册 DSH 的 javascriptProxy、文档脚本或 console 桥。
@Component
export struct BrowserView {
  @Prop stageLeft: number = 0;
  @Prop stageTop: number = 0;
  @Prop stageWidth: number = 0;
  @Prop stageHeight: number = 0;
  @Watch('visibilityChanged') @Prop visible: boolean = false;
  control: BrowserControl = new BrowserControl();
  isHostVisible: () => boolean = () => false;
  onClose: () => void = () => {};
  onStartAgent: () => void = () => {};
  onStopAgent: () => void = () => {};
  onConfirmPage: () => void = () => {};
  onNavigationFailure: () => void = () => {};
  @Prop agentMessage: string = '';

  aboutToAppear(): void {
    this.control.attach(this.isHostVisible, (target: string): boolean => this.openAuthorized(target),
      (): BrowserObservation | null => this.observePage(),
      (): Promise<string> => this.controller.runJavaScript(BROWSER_OBSERVE_SCRIPT),
      (offset: number): void => { this.controller.scrollBy(0, offset); },
      (ref: string): Promise<string> => {
        const index = Number(ref.slice(1));
        const script = BROWSER_CLICK_SCRIPT_TEMPLATE.replace(BROWSER_CLICK_INDEX_PLACEHOLDER, String(index));
        return this.controller.runJavaScript(script);
      });
    this.control.setVisible(this.visible);
  }

  aboutToDisappear(): void { this.control.detach(); }
  private visibilityChanged(): void { this.control.setVisible(this.visible); }

  private openAuthorized(target: string): boolean {
    const normalized = target.trim();
    if (!this.allowed(normalized)) { return false; }
    this.control.navigationChanged();
    try { this.controller.loadUrl(normalized); return true; } catch (error) { return false; }
  }

  private observePage(): BrowserObservation | null {
    try {
      const current = this.controller.getUrl();
      // about:blank is only eligible for an approved open, never observe.
      if (current !== 'about:blank' && !this.allowed(current)) { return null; }
      return { generation: 0, title: this.controller.getTitle(), url: current };
    } catch (error) { return null; }
  }
  @State private address: string = '';
  @State private error: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();

  private allowed(target: string): boolean {
    try {
      const parsed = new url.URL(target);
      const protocol = parsed.protocol.toLowerCase().replace(/:$/, '');
      return (protocol === 'http' || protocol === 'https') && parsed.hostname !== '';
    } catch (error) { return false; }
  }

  // A user-initiated navigation is not the approved relay open and must not
  // supply its completion evidence or leave that relay bound to another page.
  private manualNavigation(): void {
    this.control.consumeRebind();
    this.onNavigationFailure();
    this.control.navigationChanged();
  }

  private navigate(): void {
    const target = this.address.trim();
    if (!this.allowed(target)) {
      this.error = '请输入完整的 http:// 或 https:// 地址';
      return;
    }
    this.error = '';
    this.manualNavigation();
    try { this.controller.loadUrl(target); } catch (error) { this.error = '无法打开地址'; }
  }

  build() {
    Column() {
      Row({ space: 4 }) {
        Button('‹').width(36).onClick(() => {
          try {
            if (this.controller.accessBackward()) {
              this.manualNavigation();
              this.controller.backward();
            }
          } catch (error) {}
        })
        Button('›').width(36).onClick(() => {
          try {
            if (this.controller.accessForward()) {
              this.manualNavigation();
              this.controller.forward();
            }
          } catch (error) {}
        })
        TextInput({ text: this.address, placeholder: 'https://…' })
          .layoutWeight(1)
          .onChange((value: string) => { this.address = value; })
          .onSubmit(() => { this.navigate(); })
        Button('↵').width(36).onClick(() => { this.navigate(); })
        Button('↻').width(36).onClick(() => {
          this.manualNavigation();
          try { this.controller.refresh(); } catch (error) {}
        })
        Button('×').width(36).onClick(() => { this.onClose(); })
      }.width('100%')
      Row({ space: 8 }) {
        Button('启动浏览器 Agent').onClick(() => { this.onStartAgent(); })
        Button('停止 Agent').onClick(() => { this.onStopAgent(); })
        Button('确认当前页面并恢复').onClick(() => { this.onConfirmPage(); })
      }.width('100%')
      Text('需启用 browserAgent 插件。会话 ID 是不可信标签，不是鉴权；只读/工作区修改模式每次操作需同意，自动审查/完全权限模式自动放行。页面结束不代表网络稳定；同 URL 旧事件和后续 SPA 变化无法排除。').fontSize(12).width('100%')
      if (this.agentMessage !== '') { Text(this.agentMessage).fontColor('#B3261E').fontSize(12).width('100%') }
      if (this.error !== '') { Text(this.error).fontColor('#B3261E').fontSize(12) }
      Web({ src: 'about:blank', controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(false)
        .databaseAccess(false)
        .multiWindowAccess(false)
        .width('100%')
        .layoutWeight(1)
        .onLoadIntercept((event: OnLoadInterceptEvent) => {
          try {
            if (!event.data.isMainFrame()) { return false; }
            if (this.allowed(event.data.getRequestUrl())) { return false; }
            this.control.consumeRebind();
            this.onNavigationFailure();
            return true;
          } catch (error) {
            this.control.consumeRebind();
            this.onNavigationFailure();
            return true;
          }
        })
        .onErrorReceive((event) => {
          try { if (!event || event.request.isMainFrame()) { this.control.consumeRebind(); this.onNavigationFailure(); } }
          catch (_error) { this.control.consumeRebind(); this.onNavigationFailure(); }
        })
        .onHttpErrorReceive((event) => {
          try { if (!event || event.request.isMainFrame()) { this.control.consumeRebind(); this.onNavigationFailure(); } }
          catch (_error) { this.control.consumeRebind(); this.onNavigationFailure(); }
        })
        .onPageBegin((event) => { this.control.pageBegin(event?.url || ''); })
        .onPageEnd((event) => {
          this.control.pageEnd(event?.url || '');
          try {
            const current = this.controller.getUrl();
            if (this.allowed(current)) { this.address = current; this.error = ''; }
          } catch (error) {}
        })
    }
    .width(this.stageWidth)
    .height(this.stageHeight)
    .position({ x: this.stageLeft, y: this.stageTop })
    .visibility(this.visible ? Visibility.Visible : Visibility.Hidden)
    .clip(true)
    .backgroundColor('#FFFFFF')
  }
}
