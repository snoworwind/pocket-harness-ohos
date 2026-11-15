import { abilityAccessCtrl, common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { geoLocationManager } from '@kit.LocationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = '[BackgroundKeepAlive]';

// 后台保活：照 HiSH 的做法用「定位」连续任务。
// 鸿蒙会把进入后台的应用进程冻结，Web 界面背后的 dsh 引擎也跟着停；
// 起一个 LOCATION 类型的连续任务后，应用在后台仍被当作前台服务对待。
// 需要 ohos.permission.KEEP_BACKGROUND_RUNNING 与 module.json5 里的
// backgroundModes: ["location"]，以及用户授权模糊定位。
export class BackgroundKeepAlive {
  private active: boolean = false;
  private listening: boolean = false;

  async start(context: common.UIAbilityContext): Promise<boolean> {
    if (this.active) { return true; }
    try {
      const granted = await this.ensureLocationPermission(context);
      if (!granted) {
        hilog.info(0x0000, TAG, 'location permission not granted, keep-alive disabled');
        return false;
      }
      // 订阅定位变化：连续任务要求确实有定位消费，否则系统会回收。
      if (!this.listening) {
        geoLocationManager.on('locationChange', {
          interval: 15,
          locationScenario: geoLocationManager.PowerConsumptionScenario.LOW_POWER_CONSUMPTION
        }, () => {});
        this.listening = true;
      }
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: context.abilityInfo.bundleName,
            abilityName: context.abilityInfo.name
          }
        ],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(
        context, backgroundTaskManager.BackgroundMode.LOCATION, agent);
      this.active = true;
      hilog.info(0x0000, TAG, 'continuous task started');
      return true;
    } catch (error) {
      hilog.info(0x0000, TAG, 'start failed: ' + (error as Error).message);
      return false;
    }
  }

  async stop(context: common.UIAbilityContext): Promise<void> {
    try {
      if (this.listening) {
        geoLocationManager.off('locationChange');
        this.listening = false;
      }
      if (this.active) {
        await backgroundTaskManager.stopBackgroundRunning(context);
        this.active = false;
      }
    } catch (error) {
      hilog.info(0x0000, TAG, 'stop failed: ' + (error as Error).message);
    }
  }

  private async ensureLocationPermission(context: common.UIAbilityContext): Promise<boolean> {
    const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const result = await manager.requestPermissionsFromUser(context, ['ohos.permission.APPROXIMATELY_LOCATION']);
    return result.authResults.length > 0 && result.authResults[0] === 0;
  }
}
