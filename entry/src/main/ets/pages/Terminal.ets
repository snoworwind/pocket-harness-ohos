import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { window } from '@kit.ArkUI';
import { KeyboardAvoidMode as UIKeyboardAvoidMode } from '@ohos.arkui.UIContext';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { execStart, execPoll, execRelease, execWrite, execResize, execTerminate } from 'iec';
import { NativeRuntime } from '../platform/NativeRuntime';
import terminal from 'libdsh_terminal.so';

interface TerminalNative {
  create(cols: number, rows: number): number;
  destroy(handle: number): void;
  input(handle: number, data: Uint8Array): void;
  resize(handle: number, cols: number, rows: number): void;
  copyScreen(handle: number, buffer: ArrayBuffer): number;
  scrollbackCount(handle: number): number;
  copyScrollback(handle: number, index: number, buffer: ArrayBuffer): number;
  cursor(handle: number): number;
  cellBytes(): number;
  readOutput(handle: number): string;
}

interface CellData {
  ch: string;
  fg: number;
  bg: number;
  attrs: number;
  width: number;
}

const term = terminal as TerminalNative;

const CELL_BYTES = 16;
const FONT_SIZE = 14;
const DEFAULT_FG = '#d6d6d6';
const DEFAULT_BG = '#101113';

class TerminalSession {
  private id: number = -1;
  private timer: number = -1;
  private base64 = new util.Base64Helper();
  private encoder = new util.TextEncoder();
  private pending: Uint8Array = new Uint8Array(0);
  private onOutput: (bytes: Uint8Array) => void;
  private onExit: (code: number) => void;
  ended: boolean = false;

  constructor(command: string, args: string[], cwd: string, env: Record<string, string>,
    onOutput: (bytes: Uint8Array) => void, onExit: (code: number) => void) {
    this.onOutput = onOutput;
    this.onExit = onExit;
    const handle = execStart({ cmd: command, args: args, cwd: cwd, env: env, envReplace: true,
      keepStdinOpen: true, pty: true, cols: 80, rows: 24, timeoutMs: 0, maxOutputBytes: 67108864 });
    this.id = handle.id;
    this.timer = setInterval(() => this.poll(), 25);
  }

  private poll(): void {
    if (this.ended) return;
    try {
      this.flushInput();
      const chunk = execPoll(this.id, 65536, 65536, 'base64');
      if (chunk.out) this.onOutput(this.base64.decodeSync(chunk.out));
      if (chunk.err) this.onOutput(this.base64.decodeSync(chunk.err));
      if (!chunk.running && chunk.outEof && chunk.errEof) {
        this.ended = true;
        clearInterval(this.timer);
        execRelease(this.id);
        this.onExit(chunk.code);
      }
    } catch (error) {
      this.ended = true;
      clearInterval(this.timer);
      this.onExit(-1);
    }
  }

  write(text: string): void {
    if (this.ended || text.length === 0) return;
    const data = this.encoder.encodeInto(text);
    const joined = new Uint8Array(this.pending.length + data.length);
    joined.set(this.pending); joined.set(data, this.pending.length);
    this.pending = joined;
    this.flushInput();
  }

  private flushInput(): void {
    if (this.pending.length === 0) return;
    const count = execWrite(this.id, this.pending.subarray(0, 16384));
    if (count > 0) this.pending = this.pending.slice(count);
    else if (count < 0) this.pending = new Uint8Array(0);
  }

  resize(cols: number, rows: number): void {
    if (!this.ended) execResize(this.id, cols, rows);
  }

  close(): void {
    if (this.ended) return;
    this.onOutput = () => {};
    this.onExit = () => {};
    try { execTerminate(this.id, 0); } catch (error) { /* 已退出 */ }
  }
}

@Component
export struct TerminalView {
  runtime?: NativeRuntime;
  onClose: () => void = () => {};
  // 页面 tab body 的矩形（vp == CSS 像素）与可见性，由 Index 从桥消息里更新。
  // 名字带 stage 前缀：width/height 与组件自身的同名属性方法冲突。
  @Prop stageLeft: number = 0;
  @Prop stageTop: number = 0;
  // 当前会话的工作目录（页面从宿主 API 解析后下发）；空则退回工作区根目录。
  @Prop @Watch('onWorkspaceCwdChange') workspaceCwd: string = '';
  private appliedCwd: string = '';
  @Prop stageWidth: number = 0;
  @Prop stageHeight: number = 0;
  @Prop visible: boolean = true;
  @State private status: string = '正在启动终端';
  @State private ready: boolean = false;
  @State private keyBar: boolean = true;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private handle: number = 0;
  private session?: TerminalSession;
  private screenBuf: ArrayBuffer = new ArrayBuffer(0);
  private cellBuf: ArrayBuffer = new ArrayBuffer(0);
  private cols: number = 80;
  private rows: number = 24;
  private cellW: number = 8;
  private cellH: number = 18;
  private dirty: boolean = true;
  private timer: number = -1;
  private sbOffset: number = 0;
  private scrollbackCount: number = 0;
  @State private input: string = '';
  private lastY: number = 0;
  private viewW: number = 0;
  private viewH: number = 0;
  @State private keyboardHeight: number = 0;
  private win?: window.Window;
  private previousKeyboardMode: UIKeyboardAvoidMode = UIKeyboardAvoidMode.OFFSET;
  private active: boolean = false;
  private keyboardChanged = (height: number): void => {
    this.keyboardHeight = this.getUIContext().px2vp(height);
    this.sbOffset = 0;
    this.dirty = true;
  };
  private context?: common.UIAbilityContext;
  private root: string = '';

  aboutToAppear(): void {
    this.active = true;
    try { this.context = this.getUIContext().getHostContext() as common.UIAbilityContext; } catch (error) { /* 无上下文 */ }
    this.previousKeyboardMode = this.getUIContext().getKeyboardAvoidMode();
    this.getUIContext().setKeyboardAvoidMode(UIKeyboardAvoidMode.NONE);
    const context = this.context;
    if (context) window.getLastWindow(context).then((win: window.Window) => {
      if (!this.active) return;
      this.win = win;
      win.on('keyboardHeightChange', this.keyboardChanged);
      this.keyboardChanged(win.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD).bottomRect.height);
    }).catch(() => {});
    this.start();
    this.timer = setInterval(() => this.tick(), 33);
  }

  aboutToDisappear(): void {
    this.active = false;
    this.win?.off('keyboardHeightChange', this.keyboardChanged);
    this.getUIContext().setKeyboardAvoidMode(this.previousKeyboardMode);
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
    this.session?.close();
    if (this.handle !== 0) { term.destroy(this.handle); this.handle = 0; }
  }

  private tick(): void {
    if (!this.ready || !this.dirty) return;
    this.dirty = false;
    this.draw();
  }

  // 页面切换到其它会话时，把 shell 跟到新的工作目录（同一个终端会话不重建）。
  onWorkspaceCwdChange(): void {
    const cwd = this.workspaceCwd;
    if (cwd === '' || cwd === this.appliedCwd || !this.session) { return; }
    this.appliedCwd = cwd;
    this.writeCd(cwd);
  }

  // cwd 里的换行/回车/NUL 会把后续内容拼成下一条 shell 命令，直接不发送 cd；
  // 单引号仍按原逻辑转义。exec 的 cwd 不经过 shell 解析，终端仍落在该目录。
  private writeCd(cwd: string): void {
    if (cwd === '' || /[\n\r\u0000]/.test(cwd)) {
      hilog.warn(0, 'DSH_TERM', 'skip cd: cwd contains control characters');
      return;
    }
    this.session?.write("cd '" + cwd.replace(/'/g, "'\\''") + "'\n");
  }

  private async start(): Promise<void> {
    const context = this.context;
    if (!context) { this.status = '没有应用上下文'; return; }
    const runtime = this.runtime;
    if (!runtime) { this.status = '运行时未就绪'; return; }
    try {
      // 复用 Index 的运行时：probeCaps/startIecServer 已经在 ensure() 里做过。
      hilog.info(0, 'DSH_TERM', 'ensure runtime');
      await runtime.ensure();
      if (!this.active) return;
      this.root = runtime.rootDir;
      if (this.root === '') { this.status = '运行时目录为空'; return; }
      this.status = '正在启动 bash';
      hilog.info(0, 'DSH_TERM', 'create screen');
      this.handle = term.create(this.cols, this.rows) as number;
      hilog.info(0, 'DSH_TERM', 'screen created: %{public}s', this.handle.toString());
      if (this.handle === 0) { this.status = 'libvterm 初始化失败'; return; }
      this.screenBuf = new ArrayBuffer(this.cols * this.rows * CELL_BYTES);
      hilog.info(0, 'DSH_TERM', 'start bash');
      const env: Record<string, string> = runtime.environment;
      env['TERM'] = 'xterm-256color';
      env['COLORTERM'] = 'truecolor';
      env['SHELL'] = this.root + '/bin/bash';
      // 终端要落在项目/工作区目录：exec 的 cwd 偶尔会被沙箱改写成根目录，
      // 这里再显式 cd 一次兜底（PWD 也一并设好，避免提示符显示 /）。
      const workspace = this.workspaceCwd !== '' ? this.workspaceCwd : runtime.workspaceDirectory();
      this.appliedCwd = workspace;
      env['PWD'] = workspace;
      this.session = new TerminalSession(this.root + '/bin/bash', ['-i'], workspace, env,
        (bytes: Uint8Array) => {
          term.input(this.handle, bytes);
          const reply = term.readOutput(this.handle);
          if (reply !== '') this.session?.write(reply);
          this.dirty = true;
        },
        (code: number) => { this.status = 'bash 已退出（' + code.toString() + '）'; });
      this.writeCd(workspace);
      this.status = '';
      this.ready = true;
      hilog.info(0, 'DSH_TERM', 'bash started');
      this.dirty = true;
    } catch (error) {
      this.status = '终端启动失败：' + (error as Error).message;
    }
  }

  private colorOf(value: number, fallback: string): string {
    if (value === 0xFFFFFFFF) return fallback;
    return '#' + (value & 0xFFFFFF).toString(16).padStart(6, '0');
  }

  private drawCell(x: number, y: number, ch: string, fg: number, bg: number, attrs: number, width: number): void {
    let foreground = this.colorOf(fg, DEFAULT_FG);
    let background = this.colorOf(bg, DEFAULT_BG);
    if ((attrs & 8) !== 0) {
      const swap = foreground; foreground = background; background = swap;
    }
    if (background !== DEFAULT_BG) {
      this.ctx.fillStyle = background;
      this.ctx.fillRect(x, y, this.cellW * width, this.cellH);
    }
    if (ch === '' || ch === '\u0000') return;
    if (ch === ' ' && bg === 0xFFFFFFFF && attrs === 0) return;
    this.ctx.fillStyle = foreground;
    this.ctx.font = ((attrs & 4) !== 0 ? 'italic ' : '') + ((attrs & 1) !== 0 ? 'bold ' : '') +
      this.getUIContext().vp2px(FONT_SIZE).toString() + 'px monospace';
    this.ctx.fillText(ch, x, y + this.cellH - 4);
    if ((attrs & 2) !== 0) {
      const w = this.cellW * width;
      this.ctx.fillRect(x, y + this.cellH - 2, w, 1);
    }
    if ((attrs & 32) !== 0) this.ctx.fillRect(x, y + this.cellH / 2, this.cellW * width, 1);
  }

  private decodeCell(buffer: ArrayBuffer, index: number): CellData {
    const view = new DataView(buffer);
    const off = index * CELL_BYTES;
    const code = view.getUint32(off, true);
    const ch = code > 0 && code <= 0x10FFFF ? String.fromCodePoint(code) : '';
    return {
      ch: ch, fg: view.getUint32(off + 4, true), bg: view.getUint32(off + 8, true),
      attrs: view.getUint8(off + 12), width: Math.max(1, view.getUint8(off + 13))
    };
  }

  private draw(): void {
    if (this.handle === 0) return;
    // The canvas is the authority on the usable area. Resizing it is reported
    // through onAreaChange while the soft keyboard is up, but the change back
    // when the keyboard closes is not, and a stale height would leave the PTY
    // with the rows it had while the keyboard covered the screen.
    if (this.ctx.width > 0 && this.ctx.height > 0) {
      this.viewW = this.ctx.width;
      this.viewH = this.ctx.height;
    }
    const width = this.viewW;
    const height = this.viewH;
    if (width < 10 || height < 10) { this.dirty = true; return; }
    this.ctx.fillStyle = DEFAULT_BG;
    this.ctx.fillRect(0, 0, width, height);
    this.ctx.font = vp2px(FONT_SIZE).toString() + 'px monospace';
    this.ctx.textBaseline = 'alphabetic';
    this.cellW = Math.max(1, this.ctx.measureText('M').width);
    this.cellH = Math.round(FONT_SIZE * 1.35);
    const visibleRows = Math.max(1, Math.floor(height / this.cellH));
    const visibleCols = Math.max(2, Math.floor(width / this.cellW));

    if (visibleCols !== this.cols || visibleRows !== this.rows) {
      this.cols = visibleCols;
      this.rows = visibleRows;
      hilog.info(0, 'DSH_TERM', 'resize view %{public}s x %{public}s -> %{public}d x %{public}d',
        this.viewW.toString(), this.viewH.toString(), this.cols, this.rows);
      term.resize(this.handle, this.cols, this.rows);
      this.session?.resize(this.cols, this.rows);
      this.sbOffset = 0;
      this.screenBuf = new ArrayBuffer(this.cols * this.rows * CELL_BYTES);
    }

    const cells = term.copyScreen(this.handle, this.screenBuf) as number;
    if (cells <= 0) return;
    this.scrollbackCount = term.scrollbackCount(this.handle) as number;
    if (this.sbOffset > this.scrollbackCount) this.sbOffset = this.scrollbackCount;

    if (this.cellBuf.byteLength < this.cols * CELL_BYTES) {
      this.cellBuf = new ArrayBuffer(this.cols * CELL_BYTES);
    }
    let y = 0;
    // 回看区：从最新的一行往前画。
    const sbRows = Math.min(this.sbOffset, Math.floor(height / this.cellH));
    for (let i = 0; i < sbRows; i++) {
      const index = this.scrollbackCount - this.sbOffset + i;
      if ((term.copyScrollback(this.handle, index, this.cellBuf) as number) < 0) break;
      for (let col = 0; col < this.cols; col++) {
        const cell = this.decodeCell(this.cellBuf, col);
        this.drawCell(col * this.cellW, y, cell.ch, cell.fg, cell.bg, cell.attrs, cell.width);
      }
      y += this.cellH;
    }
    const screenRows = Math.min(this.rows, visibleRows - sbRows);
    for (let row = 0; row < screenRows; row++) {
      for (let col = 0; col < Math.min(this.cols, visibleCols); col++) {
        const cell = this.decodeCell(this.screenBuf, row * this.cols + col);
        this.drawCell(col * this.cellW, y, cell.ch, cell.fg, cell.bg, cell.attrs, cell.width);
      }
      y += this.cellH;
    }
    // 光标只在没有滚动时画。
    if (this.sbOffset === 0) {
      const cursor = term.cursor(this.handle) as number;
      const visible = (cursor & 1) !== 0;
      const col = (cursor >> 1) & 0x7FFF;
      const row = (cursor >> 16) & 0xFFFF;
      if (visible && row < screenRows && col < visibleCols) {
        const cy = sbRows * this.cellH + row * this.cellH;
        this.ctx.fillStyle = '#8ab4f8';
        this.ctx.fillRect(col * this.cellW, cy, this.cellW, this.cellH - 2);
      }
    }
  }

  private send(text: string): void {
    this.sbOffset = 0;
    this.session?.write(text);
    this.dirty = true;
  }

  private onTextChange(value: string): void {
    let common = 0;
    while (common < value.length && common < this.input.length && value[common] === this.input[common]) common++;
    const removed = this.input.length - common;
    if (removed > 0) this.send('\u007f'.repeat(removed));
    const added = value.slice(common);
    this.input = value;
    if (added.length > 0) this.send(added);
  }

  build() {
    Stack() {
      Column() {
        Stack() {
          Canvas(this.ctx)
            .width('100%')
            .height('100%')
            .backgroundColor(DEFAULT_BG)
            .onReady(() => {
              if (this.ctx.width > 0) { this.viewW = this.ctx.width; this.viewH = this.ctx.height; }
              this.dirty = true;
            })
            .onAreaChange((_old: Area, area: Area) => {
              this.viewW = Number(area.width);
              this.viewH = Number(area.height);
              this.dirty = true;
            })
            .onTouch((event: TouchEvent) => {
              if (event.touches.length === 1 && event.type === TouchType.Move) {
                const dy = event.touches[0].y - this.lastY;
                if (Math.abs(dy) > 8) {
                  this.sbOffset = Math.max(0, Math.min(this.scrollbackCount, this.sbOffset + (dy > 0 ? 1 : -1)));
                  this.lastY = event.touches[0].y;
                  this.dirty = true;
                }
              } else if (event.type === TouchType.Down) {
                this.lastY = event.touches[0].y;
              }
            })
        }
        .width('100%')
        .layoutWeight(1)
        Text(this.status)
          .fontSize(10)
          .fontColor('#80ff80')
          .width('100%')
          .padding({ left: 8 })
        if (this.keyBar) {
          Scroll() {
            Row({ space: 6 }) {
              this.keyButton('Esc', '\u001b')
              this.keyButton('Tab', '\t')
              this.keyButton('Ctrl-C', '\u0003')
              this.keyButton('Ctrl-D', '\u0004')
              this.keyButton('Ctrl-Z', '\u001a')
              this.keyButton('←', '\u001b[D')
              this.keyButton('↑', '\u001b[A')
              this.keyButton('↓', '\u001b[B')
              this.keyButton('→', '\u001b[C')
              this.keyButton('Enter', '\n')
              Button('输入')
                .fontSize(12)
                .height(30)
                .backgroundColor('#26282c')
                .fontColor('#d6d6d6')
                .onClick(() => { this.getUIContext().getFocusController().requestFocus('term-input'); })
            }.padding({ left: 8, right: 8, top: 6, bottom: 6 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .width('100%')
          .backgroundColor('#17181b')
        }
        TextInput({ text: this.input, placeholder: '输入命令，回车执行' })
          .width('100%').height(40)
          .fontSize(14)
          .fontColor(DEFAULT_FG)
          .backgroundColor('#17181b')
          .id('term-input')
          .onChange((value: string) => this.onTextChange(value))
          .onSubmit(() => { this.send('\n'); this.input = ''; })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(DEFAULT_BG)

      if (!this.ready) {
        Column({ space: 10 }) {
          LoadingProgress().width(36).height(36)
          Text(this.status).fontSize(13).fontColor('#9aa0a6')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(DEFAULT_BG)
      }
    }
    // The page owns the tab and its geometry: this view is only the surface that
    // fills the rectangle the tab body reported, so the sidebar and the dock
    // around it stay the page's business.
    .width(this.stageWidth)
    .height(this.stageHeight)
    .position({ x: this.stageLeft, y: this.stageTop })
    .visibility(this.visible ? Visibility.Visible : Visibility.Hidden)
    .padding({ bottom: this.keyboardHeight })
    .backgroundColor(DEFAULT_BG)
  }

  @Builder
  keyButton(label: string, seq: string) {
    Button(label)
      .fontSize(12)
      .height(30)
      .backgroundColor('#26282c')
      .fontColor('#d6d6d6')
      .onClick(() => this.send(seq))
  }
}
