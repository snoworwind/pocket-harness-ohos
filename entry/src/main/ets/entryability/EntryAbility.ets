import { UIAbility, ConfigurationConstant, common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { fileIo as fs } from '@kit.CoreFileKit';
import BuildProfile from 'BuildProfile';

// 沉浸式：始终全屏布局（内容铺到状态栏/手势条下方），系统栏按设置显示或隐藏。
//
// 早期版本在「显示系统状态栏与底部手势条」打开时把 setWindowLayoutFullScreen
// 关掉，结果系统栏占据独立的一条，页面背景与栏区割裂，上下失去沉浸感；而且
// 部分设备上栏底色被系统刷成白色。现在两种模式都保持全屏布局，打开的只是
// 系统栏本身的可见性：栏区透明地盖在应用背景上，Index 再按避让区给内容留边。
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
    // 两种模式都全屏：显示系统栏时栏区覆盖在应用背景上，不再单独占一条。
    try { win.setWindowLayoutFullScreen(true); } catch (error) { /* 忽略 */ }
    try {
      if (showBars) {
        win.setWindowSystemBarEnable(['status', 'navigation']);
      } else {
        win.setWindowSystemBarEnable([]);
      }
    } catch (error) { /* 忽略 */ }
    this.applySystemBarColors(win);
  }

  // 栏区透明，露出下面 Index 同步成页面主题色的窗口背景；图标/文字颜色跟随
  // 深浅模式。部分设备会忽略 color 只保留透明，这也是显示系统栏时仍要全屏的
  // 原因：透明栏盖在应用背景上，不会出现一条系统白底。
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
