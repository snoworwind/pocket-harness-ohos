import { BrowserBridgeApproval } from '../platform/BrowserBridge';

// Independent opt-in panel; no bridge or Index integration is performed here.
// The host must mount the view before requesting and call cancel() on bridge
// closure. A session label is a host assertion, not authentication.
export class BrowserConsentControl {
  private listener?: (details: BrowserBridgeApproval | null, token: number) => void;
  private pending?: (allowed: boolean) => void;
  private timer: number = -1;
  private serial: number = 0;
  private deadline: number = 0;
  private disposed: boolean = false;

  attach(listener: (details: BrowserBridgeApproval | null, token: number) => void): boolean {
    if (this.disposed || this.listener) { return false; }
    this.listener = listener;
    return true;
  }

  // Relay expires at 29 seconds on the native side; reject earlier so the user
  // sees a deterministic denial rather than a disappearing approval dialog.
  request(details: BrowserBridgeApproval, timeoutMs: number = 25000): Promise<boolean> {
    if (this.disposed || !this.listener || this.pending || !Number.isFinite(timeoutMs) || timeoutMs <= 0) {
      return Promise.resolve(false);
    }
    const copy: BrowserBridgeApproval = { operation: details.operation, sessionId: details.sessionId,
      pageTitle: details.pageTitle, pageUrl: details.pageUrl, targetUrl: details.targetUrl, direction: details.direction,
      ref: details.ref, key: details.key, action: details.action, textLength: details.textLength };
    const token = ++this.serial;
    return new Promise<boolean>((resolve: (allowed: boolean) => void) => {
      this.pending = resolve;
      this.deadline = Date.now() + timeoutMs;
      this.timer = setTimeout(() => this.decide(token, false), timeoutMs);
      try { this.listener?.(copy, token); } catch (_error) { this.decide(token, false); }
    });
  }

  decide(token: number, allowed: boolean): void {
    if (!this.pending || token !== this.serial) { return; }
    const resolve = this.pending;
    const result = allowed === true && !this.disposed && Date.now() < this.deadline;
    this.pending = undefined;
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    try { this.listener?.(null, token); } catch (_error) {}
    resolve(result);
  }

  cancel(): void { this.decide(this.serial, false); }

  // Permanent disposal: a destroyed view/control is never reused.
  destroy(): void {
    if (this.disposed) { return; }
    this.disposed = true;
    this.cancel();
    this.listener = undefined;
  }
}

@Component
export struct BrowserConsentView {
  control: BrowserConsentControl = new BrowserConsentControl();
  @State private details: BrowserBridgeApproval | null = null;
  @State private token: number = 0;
  private attached: boolean = false;

  aboutToAppear(): void {
    this.attached = this.control.attach((details: BrowserBridgeApproval | null, token: number): void => {
      this.details = details;
      this.token = token;
    });
  }

  aboutToDisappear(): void {
    if (this.attached) { this.control.destroy(); this.attached = false; }
  }

  @Builder
  private actions(token: number) {
    Row({ space: 12 }) {
      Button('拒绝').onClick(() => { this.control.decide(token, false); })
      Button('本次允许').onClick(() => { this.control.decide(token, true); })
    }
  }

  build() {
    if (this.details !== null) {
      Column({ space: 10 }) {
        Text('浏览器 Agent 逐次授权').fontSize(20).fontWeight(FontWeight.Bold)
        Scroll() {
          Column({ space: 8 }) {
            Text('会话 ID（仅为宿主提供的标签，不是独立鉴权）：').width('100%')
            Text(this.details.sessionId).width('100%').wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
            Text('操作：').width('100%')
            Text(this.details.operation).width('100%').wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
            Text('当前页面标题：').width('100%')
            Text(this.details.pageTitle).width('100%').wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
            Text('当前页面完整地址：').width('100%')
            Text(this.details.pageUrl).width('100%').wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
            if (this.details.operation === 'open') {
              Text('open 目标完整地址：').width('100%')
              Text(this.details.targetUrl).width('100%').wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
            }
            if (this.details.operation === 'scroll') {
              Text(this.details.direction === 'up' ? '向上滚动 400vp' : '向下滚动 400vp').width('100%')
              Text('滚动可能触发懒加载、网络请求和页面脚本；提交不保证实际移动或页面稳定，后续观察仍需逐次授权。').width('100%')
            }
            Text('读取页面时，可见正文和控件标签会提供给 Agent，可能包含隐私信息；不会主动读取表单值。25 秒内未答复会自动拒绝。').width('100%')
            Text('目标可能重定向；网页内容不可信，勿将其视为授权指令。').width('100%')
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.width('100%').layoutWeight(1)
        this.actions(this.token)
      }.width('100%').height('100%').padding(16).backgroundColor('#FFFFFF')
    }
  }
}
