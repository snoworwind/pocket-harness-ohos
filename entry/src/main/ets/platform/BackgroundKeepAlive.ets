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
//
// 启停是异步的（权限弹窗、WantAgent、连续任务都返回 Promise），而调用方
// （Index）只按「想要的开关状态」轮询。这里用一条串行队列 + 代号（generation）
// 保证顺序：
//   - start/stop 严格按请求顺序执行，不会交叉；
//   - 任何等待点之后发现代号已变，就说明有更新的请求，本次启动自行回滚；
//   - 启动中途失败或被取代时，撤销本次建立的定位订阅与已启动的连续任务。
export class BackgroundKeepAlive {
  private active: boolean = false;
  private listening: boolean = false;
  // 最新一次请求的代号：只有它还等于当前代号时，进行中的步骤才继续。
  private generation: number = 0;
  // 串行链：上一次操作结束后才执行下一次，避免 start/stop 交错。
  private tail: Promise<void> = Promise.resolve();

  start(context: common.UIAbilityContext): Promise<boolean> {
    const generation = ++this.generation;
    const run = this.tail.then(
      () => this.doStart(context, generation),
      () => this.doStart(context, generation));
    this.tail = run.then(() => {}, () => {});
    return run;
  }

  stop(context: common.UIAbilityContext): Promise<void> {
    // stop 也要占一个代号：正在等待授权/启动的 start 会因此回滚。
    ++this.generation;
    const run = this.tail.then(
      () => this.doStop(context),
      () => this.doStop(context));
    this.tail = run.then(() => {}, () => {});
    return run;
  }

  private async doStart(context: common.UIAbilityContext, generation: number): Promise<boolean> {
    if (generation !== this.generation) { return false; }
    if (this.active) { return true; }
    // 本次调用是否由自己新建定位订阅（失败时只撤销自己建的）。
    let subscribed = false;
    try {
      const granted = await this.ensureLocationPermission(context);
      if (!granted) {
        hilog.info(0x0000, TAG, 'location permission not granted, keep-alive disabled');
        return false;
      }
      if (generation !== this.generation) { return false; }
      // 订阅定位变化：连续任务要求确实有定位消费，否则系统会回收。
      if (!this.listening) {
        geoLocationManager.on('locationChange', {
          interval: 15,
          locationScenario: geoLocationManager.PowerConsumptionScenario.LOW_POWER_CONSUMPTION
        }, () => {});
        this.listening = true;
        subscribed = true;
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
      if (generation !== this.generation) {
        this.rollbackSubscription(subscribed);
        return false;
      }
      await backgroundTaskManager.startBackgroundRunning(
        context, backgroundTaskManager.BackgroundMode.LOCATION, agent);
      if (generation !== this.generation) {
        // 连续任务刚起来就被更新的 stop 取代：立刻撤销，别让它在页面退出后继续跑。
        await this.stopRunning(context);
        this.rollbackSubscription(subscribed);
        return false;
      }
      this.active = true;
      hilog.info(0x0000, TAG, 'continuous task started');
      return true;
    } catch (error) {
      hilog.info(0x0000, TAG, 'start failed: ' + (error as Error).message);
      // 任务可能已经启动（startBackgroundRunning 抛错除外，这里统一兜底）。
      if (this.active) { await this.stopRunning(context); }
      this.rollbackSubscription(subscribed);
      return false;
    }
  }

  private async doStop(context: common.UIAbilityContext): Promise<void> {
    try {
      if (this.listening) {
        geoLocationManager.off('locationChange');
        this.listening = false;
      }
    } catch (error) {
      hilog.info(0x0000, TAG, 'unsubscribe location failed: ' + (error as Error).message);
    }
    await this.stopRunning(context);
  }

  // 只撤销本次调用新建的订阅：共享订阅由已有的 start 负责。
  private rollbackSubscription(subscribed: boolean): void {
    if (!subscribed || !this.listening) { return; }
    try {
      geoLocationManager.off('locationChange');
      this.listening = false;
    } catch (error) {
      hilog.info(0x0000, TAG, 'rollback subscription failed: ' + (error as Error).message);
    }
  }

  // stopBackgroundRunning 失败时保留 active：下次 stop 还会再试；页面退出时
  // 已经来不及重试，但至少日志里能看出是系统拒绝了。
  private async stopRunning(context: common.UIAbilityContext): Promise<void> {
    if (!this.active) { return; }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      this.active = false;
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
