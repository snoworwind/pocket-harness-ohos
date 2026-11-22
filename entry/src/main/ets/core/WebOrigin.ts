// Web 服务端口/URL 的纯函数，供壳层与宿主测试共用。
//
// 为什么端口必须跨启动稳定：ArkWeb 的 localStorage 按 origin 隔离，而 origin
// 包含端口。`dsh --port 0` 每次启动拿到的端口不同，客户端持久化的
// `dsh.sessions.current`（上次会话）和 `dsh.workspace.view.v5` 等设置就落到不同
// origin，表现为重启后回到新对话、部分设置复位。壳层持久化首次选中的端口并在
// 下次启动复用；被占用时才顺延，最后退回内核随机分配。

/** 端口是否可用于监听（避开特权端口与非法值）。 */
export function isUsableWebPort(port: number): boolean {
  return Number.isInteger(port) && port >= 1024 && port <= 65535;
}

/**
 * 生成启动 Web 服务时的端口候选：上次成功的端口 → 固定基址起顺延 → 0（内核随机）。
 * 结果去重且最后一个一定是 0，保证极端情况下仍能起来。
 */
export function webPortCandidates(saved: number, base: number, attempts: number): number[] {
  const candidates: number[] = [];
  if (isUsableWebPort(saved)) { candidates.push(saved); }
  for (let index = 0; index < attempts; index++) {
    const port = base + index;
    if (isUsableWebPort(port) && candidates.indexOf(port) < 0) { candidates.push(port); }
  }
  candidates.push(0);
  return candidates;
}

/** 从 `dsh web:` 打印的 URL 里取实际端口；解析不到返回 0。 */
export function webPortFromUrl(link: string): number {
  const match = /^https?:\/\/[^/:]+:([0-9]+)/.exec(link);
  if (!match) { return 0; }
  const port = Number(match[1]);
  return isUsableWebPort(port) ? port : 0;
}

/**
 * 是否属于「端口被占用」的启动失败。只有这一类才换端口重试；插件/运行时错误
 * 必须原样暴露，不能被重试掩盖。
 */
export function isWebPortInUse(message: string): boolean {
  return /EADDRINUSE|address already in use|listen EADDR|failed to listen|bind EADDR|端口被占用/i.test(message);
}
