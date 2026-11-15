import { webview } from '@kit.ArkWeb';

// 调试页：只放一个 Web 组件加载 rawfile 里的探针页面，
// 用来在模拟器上复现“软键盘滑入时闪白”，不启动引擎。
@Entry
@Component
struct KbTest {
  private controller: webview.WebviewController = new webview.WebviewController();
  @State private followSystem: boolean = true;

  build() {
    Stack() {
      Web({ src: $rawfile('kbtest.html'), controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .databaseAccess(true)
        .fileAccess(true)
        .imageAccess(true)
        .onlineImageAccess(true)
        .darkMode(this.followSystem ? WebDarkMode.Auto : WebDarkMode.Off)
        .forceDarkAccess(false)
        .width('100%')
        .height('100%')
        .backgroundColor('#101113')
      Column() {
        Button(this.followSystem ? 'Web 深色：跟随系统（完整界面配置）' : 'Web 深色：关闭（原探针配置）')
          .fontSize(12)
          .margin({ top: 100 })
          .onClick(() => { this.followSystem = !this.followSystem; })
        Blank()
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#101113')
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.KEYBOARD], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
