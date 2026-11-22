import { window } from '@kit.ArkUI';

// 顶部避让余量（vp）。沉浸式下交界线取挖孔避让区的底边，再往下留一点，
// 避免正好压在前摄中心。
export const IMMERSIVE_TOP_GAP = 6;

// 避让区 Rect 是相对窗口左上角的 px 坐标。顶部要让开整块区域，必须取底边
// （top + height）；部分机型挖孔 Rect 并不贴着屏幕顶边，只用 height 会把
// 交界线算到前摄中心。底部手势条的 Rect 贴着屏幕底边，height 就是要让开的高度。
export function avoidAreaBottom(rect: window.Rect): number {
  return rect.top + rect.height;
}

// 系统栏可见性同时走新老两套接口：
//   - setSpecificSystemBarEnabled（API 11+）逐个系统栏显隐，是真正能隐藏/恢复
//     状态栏的接口；
//   - setWindowSystemBarEnable 只在主窗口处于全屏主窗口状态时生效，部分版本上
//     「隐藏 → 显示」会被系统策略吞掉，表现为开关只能进沉浸式、回不来。
// 两者语义一致，同时调用不会冲突；失败只忽略，不影响页面。
export function setSystemBarVisible(win: window.Window, visible: boolean): void {
  try {
    win.setWindowSystemBarEnable(visible ? ['status', 'navigation'] : []).catch(() => {});
  } catch (error) { /* 忽略 */ }
  try {
    win.setSpecificSystemBarEnabled('status', visible, false).catch(() => {});
    win.setSpecificSystemBarEnabled('navigation', visible, false).catch(() => {});
  } catch (error) { /* 忽略 */ }
}
