'use strict';
/**
 * HarmonyOS runtime preload.
 *
 * node-addon-native-custom-loader tries `libcFromExecutable()` and
 * `libcFromProcMaps()` first. On HarmonyOS both probes miss (the loader is
 * statically linked / the sandbox maps don't carry a recognizable musl name),
 * so it falls back to `process.report.getReport()` just to distinguish musl
 * from glibc. Building that report enumerates every CPU's sysfs cpufreq entry
 * and blocks the Node event loop for roughly 30 seconds on this device.
 *
 * HarmonyOS uses musl, and the loader's own fallback would also choose musl.
 * Answer the no-argument probe with a minimal report so the expensive CPU /
 * network collection never runs. Calls that pass options still use Node's
 * original implementation.
 *
 * Guarded by IEC_SYSROOT so a developer running the engine on a desktop host
 * keeps the stock behavior.
 */
(function install() {
  // 已知问题（仅当前 x86_64 预编译 libnode）：进程内第一次浮点取模会返回 NaN，
  // 之后同一条表达式都正常。@js-temporal/polyfill 在模块初始化时第一行就是
  // `Date.now() % 1e6` 计算纪元纳秒，撞上这次冷启动会让 11 个核心服务插件
  // import 失败，Web UI 停在「Failed to load plugins」。这里先做一次无害的
  // 浮点取模，把这次冷启动消耗掉；arm64 上同样执行但无副作用。
  if (process.arch === 'x64') {
    // 必须用变量而不是字面量：纯字面量的表达式会被 V8 在解析期折叠掉，
    // 不会真正执行那一次浮点取模，也就消耗不掉这个冷启动问题。
    let warmDividend = 1.5;
    let warmDivisor = 1.1;
    void (warmDividend % warmDivisor);
  }
  if (process.platform !== 'linux') return;
  if (!process.env.IEC_SYSROOT) return;
  const report = process.report;
  if (report === undefined || typeof report.getReport !== 'function') return;
  if (process.env.DSH_LITE_REPORT === '0') return;
  const original = report.getReport.bind(report);
  report.getReport = function getReport(options) {
    if (options === undefined) return { header: {} };
    return original(options);
  };
})();
