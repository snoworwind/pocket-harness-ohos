import { UIAbility, ConfigurationConstant, common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { fileIo as fs } from '@kit.CoreFileKit';
import { setSystemBarVisible } from '../platform/WindowMode';
import BuildProfile from 'BuildProfile';

// 两种窗口模式，由设置里的「显示系统状态栏与底部手势条」决定：
//
//   沉浸式（默认）：隐藏系统状态栏/导航栏，Web 内容铺满整屏，Index 按避让区
//     给前摄挖孔与底部手势条让位；系统栏由系统在顶部下滑时临时露出。
//   非沉浸式：显示系统状态栏，内容下移到状态栏下方。
//
// 两种模式都保持 setWindowLayoutFullScreen(true)：窗口始终铺满整屏，栏区露出
// 的是应用自己画的主题背景。这样非沉浸式底部也不会出现系统白条（过去把布局
// 切回安全区时，设备会把栏区刷成系统默认白底，页面背景和栏区割裂）。
// 因此模式差异只体现在系统栏的可见性与 Index 的顶部留白，不切换布局。
//
// 开关镜像在 harness-home/harmony-native.json，这里启动时先按它决定初始状态，
// 之后由 Index 轮询应用变化（避免先全屏再跳一下）。
export default class EntryAbility extends UIAbility {
  private win?: window.Window;

  private showSystemBars(): boolean {
    try {
      const file = this.context.filesDir + '/harness-home/harmony-native.json';
      if (!fs.accessSync(file)) { return false; }
      const parsed = JSON.parse(fs.readTextSync(file)) as Record<string, boolean>;
      return parsed.showSystemBars === true;
    } catch (error) { return false; }
  }

  private immersive(win: window.Window, showBars: boolean): void {
    try { win.setWindowLayoutFullScreen(true); } catch (error) { /* 忽略 */ }
    setSystemBarVisible(win, showBars);
    this.applySystemBarColors(win);
  }

  // 栏区透明，露出下面 Index 同步成页面主题色的窗口背景；图标/文字颜色跟随
  // 深浅模式，避免深色主题下状态栏文字还是黑的。
  private applySystemBarColors(win: window.Window): void {
    const dark = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    try {
      win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: dark ? '#FFFFFF' : '#000000',
        navigationBarContentColor: dark ? '#FFFFFF' : '#000000'
      });
    } catch (error) { /* 忽略 */ }
  }

  // 窗口背景色必须在 loadContent() 之后设置才生效（官方社区明确过：loadContent 前
  // 调 setWindowBackgroundColor 会被忽略，甚至透明色会崩）。键盘滑入的那一帧露出的
  // 就是窗口底色，所以这里补一次，和页面里的设置形成双保险。
  private applyWindowBackground(win: window.Window): void {
    const dark = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    try { win.setWindowBackgroundColor(dark ? '#101113' : '#F7F7F0'); } catch (error) { /* 忽略 */ }
  }

  onWindowStageCreate(stage: window.WindowStage): void {
    // DevTools 只在 debug 构建开启；release 显式传 false，不依赖系统默认值。
    // BuildProfile 由 hvigor 在每个构建模式生成（release 时 DEBUG=false）。
    try { webview.WebviewController.setWebDebuggingAccess(BuildProfile.DEBUG); } catch (error) { /* 调试开关 */ }
    try {
      const context = this.context as common.UIAbilityContext;
      context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (error) { /* 旧版本没有该接口 */ }
    try {
      this.win = stage.getMainWindowSync();
      this.immersive(this.win, this.showSystemBars());
    } catch (error) { /* 忽略 */ }
    stage.loadContent('pages/Index').then(() => {
      const win = this.win;
      if (win) { this.applyWindowBackground(win); }
    }).catch(() => {});
  }

  onConfigurationUpdate(): void {
    if (!this.win) { return; }
    this.immersive(this.win, this.showSystemBars());
    this.applyWindowBackground(this.win);
  }
}
