import { UIAbility, ConfigurationConstant, common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import BuildProfile from 'BuildProfile';

// 沉浸式：全屏布局 + 隐藏系统栏。
//
// 这台设备上 setWindowSystemBarProperties 的 statusBarColor/navigationBarColor
// 不生效（栏区始终是系统默认白底），改色、透明栏 + 页面留白都试过，栏区仍然白。
// 于是采用官方「方式一」：直接不显示状态栏和导航栏，让 Web 内容占满整屏。
export default class EntryAbility extends UIAbility {
  private win?: window.Window;

  private immersive(win: window.Window): void {
    try { win.setWindowLayoutFullScreen(true); } catch (error) { /* 忽略 */ }
    try { win.setWindowSystemBarEnable([]); } catch (error) { /* 忽略 */ }
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
      this.immersive(this.win);
    } catch (error) { /* 忽略 */ }
    stage.loadContent('pages/Index').then(() => {
      const win = this.win;
      if (win) { this.applyWindowBackground(win); }
    }).catch(() => {});
  }

  onConfigurationUpdate(): void {
    if (!this.win) { return; }
    this.immersive(this.win);
    this.applyWindowBackground(this.win);
  }
}
