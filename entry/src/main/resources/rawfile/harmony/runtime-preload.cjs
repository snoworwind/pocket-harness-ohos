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
