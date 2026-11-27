import { webview } from '@kit.ArkWeb';
import { url } from '@kit.ArkTS';
import { BROWSER_CLICK_INDEX_PLACEHOLDER, BROWSER_CLICK_SCRIPT_TEMPLATE, BROWSER_INDEX_PLACEHOLDER,
  BROWSER_INPUT_SCRIPT_TEMPLATE, BROWSER_KEY_PLACEHOLDER, BROWSER_MODE_PLACEHOLDER,
  BROWSER_OBSERVE_SCRIPT, BROWSER_PRESS_SCRIPT_TEMPLATE, BROWSER_SELECT_SCRIPT_TEMPLATE,
  BROWSER_TEXT_PLACEHOLDER, BROWSER_ALLOWED_KEYS, BROWSER_HOVER_SCRIPT_TEMPLATE,
  BROWSER_TEXT_SCRIPT_TEMPLATE, BROWSER_TEXT_OFFSET_PLACEHOLDER, BROWSER_TEXT_LIMIT_PLACEHOLDER } from './BrowserObserveScript';

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
  private runInput: (ref: string, base64: string, mode: string) => Promise<string> = async () => { throw new Error('Browser unavailable'); };
  private runPress: (key: string) => Promise<string> = async () => { throw new Error('Browser unavailable'); };
  private runSelect: (ref: string, base64: string) => Promise<string> = async () => { throw new Error('Browser unavailable'); };
  private runHover: (ref: string) => Promise<string> = async () => { throw new Error('Browser unavailable'); };
  private runText: (offset: number, limit: number) => Promise<string> = async () => { throw new Error('Browser unavailable'); };
  private navigatePage: (action: string) => boolean = () => false;

  attach(isHostVisible: () => boolean, openPage: (target: string) => boolean,
    readPage: () => BrowserObservation | null,
    runSnapshot: () => Promise<string> = async () => { throw new Error('Browser unavailable'); },
    scrollPage: (offset: number) => void = () => { throw new Error('Browser unavailable'); },
    runClick: (ref: string) => Promise<string> = async () => { throw new Error('Browser unavailable'); },
    runInput: (ref: string, base64: string, mode: string) => Promise<string> = async () => { throw new Error('Browser unavailable'); },
    runPress: (key: string) => Promise<string> = async () => { throw new Error('Browser unavailable'); },
    runSelect: (ref: string, base64: string) => Promise<string> = async () => { throw new Error('Browser unavailable'); },
    runHover: (ref: string) => Promise<string> = async () => { throw new Error('Browser unavailable'); },
    runText: (offset: number, limit: number) => Promise<string> = async () => { throw new Error('Browser unavailable'); },
    navigatePage: (action: string) => boolean = () => false): void {
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
    this.runInput = runInput;
    this.runPress = runPress;
    this.runSelect = runSelect;
    this.runHover = runHover;
    this.runText = runText;
    this.navigatePage = navigatePage;
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
    this.runInput = async () => { throw new Error('Browser unavailable'); };
    this.runPress = async () => { throw new Error('Browser unavailable'); };
    this.runSelect = async () => { throw new Error('Browser unavailable'); };
    this.runHover = async () => { throw new Error('Browser unavailable'); };
    this.runText = async () => { throw new Error('Browser unavailable'); };
    this.navigatePage = () => false;
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
    this.validRefIndex(ref);
    const result = await this.runClick(ref);
    if (this.currentGeneration() !== generation) { throw new Error('Browser binding changed'); }
    return result;
  }

  private validRefIndex(ref: string): number {
    if (typeof ref !== 'string' || !/^e\d{1,3}$/.test(ref)) { throw new Error('Invalid element reference'); }
    const index = Number(ref.slice(1));
    if (!Number.isSafeInteger(index) || index < 0 || index >= 80) { throw new Error('Invalid element reference'); }
    return index;
  }

  private validBase64(value: string): string {
    if (typeof value !== 'string' || !/^[A-Za-z0-9+/]*={0,2}$/.test(value) || value.length > 1536) {
      throw new Error('Invalid encoded text');
    }
    return value;
  }

  // Text arrives base64-encoded; the page program decodes it. No agent or page
  // text is ever concatenated into executable source.
  async input(generation: number, ref: string, base64: string, mode: string): Promise<string> {
    if (this.currentGeneration() !== generation) { throw new Error('Browser binding changed'); }
    this.validRefIndex(ref);
    this.validBase64(base64);
    if (mode !== 'fill' && mode !== 'type') { throw new Error('Invalid input mode'); }
    const result = await this.runInput(ref, base64, mode);
    if (this.currentGeneration() !== generation) { throw new Error('Browser binding changed'); }
    return result;
  }

  async press(generation: number, key: string): Promise<string> {
    if (this.currentGeneration() !== generation) { throw new Error('Browser binding changed'); }
    if (typeof key !== 'string' || BROWSER_ALLOWED_KEYS.indexOf(key) < 0) { throw new Error('Unsupported key'); }
    const result = await this.runPress(key);
    if (this.currentGeneration() !== generation) { throw new Error('Browser binding changed'); }
    return result;
  }

  async select(generation: number, ref: string, base64: string): Promise<string> {
    if (this.currentGeneration() !== generation) { throw new Error('Browser binding changed'); }
    this.validRefIndex(ref);
    this.validBase64(base64);
    const result = await this.runSelect(ref, base64);
    if (this.currentGeneration() !== generation) { throw new Error('Browser binding changed'); }
    return result;
  }

  // Hover dispatches pointer-hover events so menus that open on mouseenter can
  // be observed. Synthetic hover does not move the real cursor; 'hovered' only
  // attests dispatch, not that any menu actually opened.
  async hover(generation: number, ref: string): Promise<string> {
    if (this.currentGeneration() !== generation) { throw new Error('Browser binding changed'); }
    this.validRefIndex(ref);
    const result = await this.runHover(ref);
    if (this.currentGeneration() !== generation) { throw new Error('Browser binding changed'); }
    return result;
  }

  // Readable text is a read-only operation, but it still needs the same
  // generation checks: a navigation mid-read must not return another page.
  async text(generation: number, offset: number, limit: number): Promise<string> {
    if (this.currentGeneration() !== generation) { throw new Error('Browser binding changed'); }
    if (!Number.isSafeInteger(offset) || offset < 0 || offset > 200000) { throw new Error('Invalid text offset'); }
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 8000) { throw new Error('Invalid text limit'); }
    const result = await this.runText(offset, limit);
    if (this.currentGeneration() !== generation) { throw new Error('Browser binding changed'); }
    return result;
  }

  // History navigation is native-only (no page script). It invalidates every
  // outstanding reference because the document changes.
  navigate(generation: number, action: string): void {
    if (this.currentGeneration() !== generation) { throw new Error('Browser binding changed'); }
    if (action !== 'back' && action !== 'forward' && action !== 'refresh') { throw new Error('Invalid navigation action'); }
    this.navigationChanged();
    if (!this.navigatePage(action)) { throw new Error('Navigation unavailable'); }
  }
}

// 独立 Web 实例：不注册 DSH 的 javascriptProxy、文档脚本或 console 桥。
@Component
export struct BrowserView {
  @Prop stageLeft: number = 0;
  @Prop stageTop: number = 0;
  @Prop stageWidth: number = 0;
  @Prop stageHeight: number = 0;
  @Prop dark: boolean = false;
  @Prop visible: boolean = false;
  @Watch('visibilityChanged') @Prop active: boolean = false;
  control: BrowserControl = new BrowserControl();
  isHostVisible: () => boolean = () => false;
  onClose: () => void = () => {};
  onStartAgent: () => void = () => {};
  onStopAgent: () => void = () => {};
  onConfirmPage: () => void = () => {};
  onNavigationFailure: () => void = () => {};
  @Prop agentMessage: string = '';
  @Prop agentConnected: boolean = false;

  aboutToAppear(): void {
    this.control.attach(this.isHostVisible, (target: string): boolean => this.openAuthorized(target),
      (): BrowserObservation | null => this.observePage(),
      (): Promise<string> => this.controller.runJavaScript(BROWSER_OBSERVE_SCRIPT),
      (offset: number): void => { this.controller.scrollBy(0, offset); },
      (ref: string): Promise<string> => {
        const index = Number(ref.slice(1));
        const script = BROWSER_CLICK_SCRIPT_TEMPLATE.replace(BROWSER_CLICK_INDEX_PLACEHOLDER, String(index));
        return this.controller.runJavaScript(script);
      },
      (ref: string, base64: string, mode: string): Promise<string> => {
        const index = Number(ref.slice(1));
        const script = BROWSER_INPUT_SCRIPT_TEMPLATE.replace(BROWSER_INDEX_PLACEHOLDER, String(index))
          .replace(BROWSER_TEXT_PLACEHOLDER, base64).replace(BROWSER_MODE_PLACEHOLDER, mode);
        return this.controller.runJavaScript(script);
      },
      (key: string): Promise<string> => {
        return this.controller.runJavaScript(BROWSER_PRESS_SCRIPT_TEMPLATE.replace(BROWSER_KEY_PLACEHOLDER, key));
      },
      (ref: string, base64: string): Promise<string> => {
        const index = Number(ref.slice(1));
        const script = BROWSER_SELECT_SCRIPT_TEMPLATE.replace(BROWSER_INDEX_PLACEHOLDER, String(index))
          .replace(BROWSER_TEXT_PLACEHOLDER, base64);
        return this.controller.runJavaScript(script);
      },
      (ref: string): Promise<string> => {
        const index = Number(ref.slice(1));
        const script = BROWSER_HOVER_SCRIPT_TEMPLATE.replace(BROWSER_CLICK_INDEX_PLACEHOLDER, String(index));
        return this.controller.runJavaScript(script);
      },
      (offset: number, limit: number): Promise<string> => {
        const script = BROWSER_TEXT_SCRIPT_TEMPLATE
          .replace(BROWSER_TEXT_OFFSET_PLACEHOLDER, String(offset))
          .replace(BROWSER_TEXT_LIMIT_PLACEHOLDER, String(limit));
        return this.controller.runJavaScript(script);
      },
      (action: string): boolean => {
        try {
          if (action === 'back') {
            if (!this.controller.accessBackward()) { return false; }
            this.controller.backward();
            return true;
          }
          if (action === 'forward') {
            if (!this.controller.accessForward()) { return false; }
            this.controller.forward();
            return true;
          }
          this.controller.refresh();
          return true;
        } catch (error) { return false; }
      });
    this.control.setVisible(this.active);
  }

  aboutToDisappear(): void { this.control.detach(); }
  private visibilityChanged(): void { this.control.setVisible(this.active); }

  private openAuthorized(target: string): boolean {
    const normalized = target.trim();
    if (!this.allowed(normalized)) { return false; }
    this.control.navigationChanged();
    try {
      this.currentUrl = normalized;
      this.loading = true;
      this.progress = 5;
      this.controller.loadUrl(normalized);
      return true;
    } catch (error) { return false; }
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
  @State private title: string = '';
  @State private currentUrl: string = 'about:blank';
  @State private loading: boolean = false;
  @State private progress: number = 0;
  private controller: webview.WebviewController = new webview.WebviewController();

  private hasPage(): boolean {
    return this.currentUrl !== '' && this.currentUrl !== 'about:blank';
  }

  private displayHost(): string {
    try {
      const parsed = new url.URL(this.currentUrl);
      return parsed.hostname !== '' ? parsed.hostname : '新标签页';
    } catch (error) { return '新标签页'; }
  }

  private mutedColor(): string { return this.dark ? '#9AA0A6' : '#697078'; }
  private surfaceColor(): string { return this.dark ? '#26282C' : '#F7F8FA'; }
  private pageColor(): string { return this.dark ? '#1E1F22' : '#FFFFFF'; }
  private lineColor(): string { return this.dark ? '#3A3D42' : '#E3E6EA'; }
  private textColor(): string { return this.dark ? '#E8EAED' : '#1F2328'; }
  private accentColor(): string { return this.dark ? '#7FB0FF' : '#2563EB'; }

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
    this.currentUrl = target;
    this.loading = true;
    this.progress = 5;
    this.title = '';
    try { this.controller.loadUrl(target); } catch (error) { this.error = '无法打开地址'; this.loading = false; }
  }

  @Builder
  private emptyState() {
    Column({ space: 10 }) {
      Stack() {
        Circle().width(58).height(58).fill(this.dark ? '#2C3648' : '#E8F0FE')
        Text('🌐').fontSize(26)
      }.width(58).height(58)
      Text('浏览器已就绪').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.textColor())
      Text('Agent 可以在这里打开网页；你也可以直接输入地址。')
        .fontSize(12).fontColor(this.mutedColor()).textAlign(TextAlign.Center)
        .maxLines(2).padding({ left: 28, right: 28 })
      Row({ space: 8 }) {
        Button(this.agentConnected ? '断开 Agent' : '连接 Agent')
          .fontSize(12).height(32).backgroundColor(this.accentColor()).fontColor('#FFFFFF')
          .onClick(() => {
            if (this.agentConnected) { this.onStopAgent(); } else { this.onStartAgent(); }
          })
        Button('确认当前页面').fontSize(12).height(32)
          .backgroundColor(this.dark ? '#303238' : '#ECEEF1').fontColor(this.textColor())
          .onClick(() => { this.onConfirmPage(); })
      }
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.pageColor())
  }

  build() {
    Column() {
      // 地址栏：与侧栏其余内容共用同一套明暗配色，避免深色主题下出现白块。
      Row({ space: 2 }) {
        Button('‹').width(34).height(32).fontSize(22).fontColor(this.textColor())
          .backgroundColor(Color.Transparent).borderRadius(8)
          .onClick(() => {
            try {
              if (this.controller.accessBackward()) {
                this.manualNavigation();
                this.controller.backward();
              }
            } catch (error) {}
          })
        Button('›').width(34).height(32).fontSize(22).fontColor(this.textColor())
          .backgroundColor(Color.Transparent).borderRadius(8)
          .onClick(() => {
            try {
              if (this.controller.accessForward()) {
                this.manualNavigation();
                this.controller.forward();
              }
            } catch (error) {}
          })
        Text(this.currentUrl.indexOf('https://') === 0 ? '🔒' : '🌐')
          .fontSize(12).width(18).textAlign(TextAlign.Center).fontColor(this.mutedColor())
        TextInput({ text: this.address, placeholder: '输入网址或搜索' })
          .layoutWeight(1)
          .height(32).fontSize(12).borderRadius(16)
          .padding({ left: 12, right: 12 })
          .fontColor(this.textColor())
          .placeholderColor(this.mutedColor())
          .backgroundColor(this.dark ? '#303238' : '#ECEEF1')
          .onChange((value: string) => { this.address = value; })
          .onSubmit(() => { this.navigate(); })
        Button('刷新').width(52).height(32).fontSize(11).fontColor(this.textColor())
          .padding(0).backgroundColor(Color.Transparent).borderRadius(8)
          .onClick(() => {
            this.manualNavigation();
            this.loading = true;
            this.progress = 5;
            try { this.controller.refresh(); } catch (error) {}
          })
        Button('关闭').width(52).height(32).fontSize(11).fontColor(this.textColor())
          .padding(0).backgroundColor(Color.Transparent).borderRadius(8)
          .onClick(() => { this.onClose(); })
      }
      .width('100%').height(46)
      .padding({ left: 4, right: 4, top: 7, bottom: 7 })
      .backgroundColor(this.surfaceColor())

      // 细进度条：加载时显示，不额外占用高度。
      Stack({ alignContent: Alignment.Start }) {
        Row().width('100%').height(2).backgroundColor(this.lineColor())
        Row().width(this.loading ? Math.max(4, this.progress) + '%' : '0%')
          .height(2).backgroundColor(this.accentColor())
      }.width('100%').height(2)

      // 页面身份与 Agent 状态：一眼能看出当前网页和 Agent 是否接通。
      Row({ space: 6 }) {
        Text(this.hasPage() ? (this.title !== '' ? this.title : this.displayHost()) : '新标签页')
          .fontSize(11).fontColor(this.mutedColor()).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        Circle().width(6).height(6)
          .fill(this.agentConnected ? '#34A853' : (this.dark ? '#5F6368' : '#A8AEB6'))
        Text(this.agentConnected ? 'Agent 已连接' : 'Agent 未连接')
          .fontSize(10).fontColor(this.agentConnected ? this.textColor() : this.mutedColor())
        Button(this.agentConnected ? '断开' : '连接')
          .fontSize(10).height(24).borderRadius(12)
          .backgroundColor(this.dark ? '#303238' : '#ECEEF1').fontColor(this.textColor())
          .onClick(() => { if (this.agentConnected) { this.onStopAgent(); } else { this.onStartAgent(); } })
        Button('确认')
          .fontSize(10).height(24).borderRadius(12)
          .backgroundColor(this.dark ? '#303238' : '#ECEEF1').fontColor(this.textColor())
          .onClick(() => { this.onConfirmPage(); })
      }
      .width('100%').height(30).padding({ left: 12, right: 8 })
      .backgroundColor(this.surfaceColor())

      if (this.agentMessage !== '') {
        Text(this.agentMessage)
          .fontColor(this.agentConnected ? this.mutedColor() : (this.dark ? '#F0B8B3' : '#8A4B45'))
          .fontSize(10).width('100%').maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 12, right: 12, top: 4, bottom: 4 })
          .backgroundColor(this.surfaceColor())
      }
      if (this.error !== '') {
        Text(this.error).fontColor('#D9534F').fontSize(11).width('100%')
          .padding({ left: 12, right: 12, top: 4, bottom: 4 })
          .backgroundColor(this.surfaceColor())
      }

      Stack({ alignContent: Alignment.TopStart }) {
        Web({ src: 'about:blank', controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(false)
        .databaseAccess(false)
        .darkMode(this.dark ? WebDarkMode.On : WebDarkMode.Off)
        .forceDarkAccess(this.dark)
        .backgroundColor(this.dark ? '#202124' : '#FFFFFF')
        .multiWindowAccess(false)
        .width('100%')
        .height('100%')
        .onProgressChange((event) => {
          const value = Number(event?.newProgress);
          if (Number.isFinite(value)) {
            this.progress = value;
            this.loading = value < 100;
          }
        })
        .onTitleReceive((event) => { this.title = event?.title || ''; })
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
        .onPageBegin((event) => {
          this.loading = true;
          this.progress = Math.max(this.progress, 5);
          if (event?.url) { this.currentUrl = event.url; }
          this.control.pageBegin(event?.url || '');
        })
        .onPageEnd((event) => {
          this.loading = false;
          this.progress = 100;
          this.control.pageEnd(event?.url || '');
          try {
            const current = this.controller.getUrl();
            if (this.allowed(current)) {
              this.address = current;
              this.currentUrl = current;
              this.error = '';
            }
            const pageTitle = this.controller.getTitle();
            if (pageTitle !== '') { this.title = pageTitle; }
          } catch (error) {}
        })
        if (!this.hasPage()) { this.emptyState() }
      }
      .width('100%').layoutWeight(1)
    }
    .width(this.stageWidth)
    .height(this.stageHeight)
    .position({ x: this.stageLeft, y: this.stageTop })
    .visibility(this.visible ? Visibility.Visible : Visibility.Hidden)
    .clip(true)
    .borderRadius(12)
    .border({ width: 1, color: this.lineColor() })
    .backgroundColor(this.pageColor())
  }
}
