/**
 * 原生终端：DSH 右侧栏里的一个 dock tab，终端画面由鸿蒙壳层绘制。
 *
 * 分工（与 pocket-harness 相同的边界）：
 *  - 本插件只注册 tab、渲染一块透明的 stage，并把 stage 的矩形上报给壳层；
 *  - 壳层在这块矩形上铺自己的终端视图，会话、PTY、键盘都归壳层；
 *  - tab 的 × 触发 close 处理器，壳层据此停止会话。
 *
 * 页面 → 壳层没有 JS 桥对象可用，走 `console.log('DSH_TERM:' + json)`，
 * 壳层用 Web 组件的 onConsole 接收。
 */
window.__ModuleLoader__.load({
  id: '@local/dsh-harmony-terminal',
  factory(require) {
    const React = require('react');
    const h = React.createElement;
    // 诊断标记：CDP 里能直接看出模块是否加载、apply 是否跑完、卡在哪一步。
    window.__dshHarmonyTerminalModule = true;

    const TAB_ID = 'harmony-native-terminal';
    const TAB_KIND = 'terminal-harmony';

    function send(op, payload) {
      try {
        console.log('DSH_TERM:' + JSON.stringify(Object.assign({ op: op }, payload)));
      } catch (error) {
        /* 控制台不可用时静默：终端本身仍然可用 */
      }
    }

    function tabOwner(props) {
      try {
        const info = props.useTabInfo && props.useTabInfo();
        const tab = info && info.tab;
        if (tab && tab.id !== undefined && tab.id !== null) return String(tab.id);
      } catch (error) {
        /* 没有 tab 信息时退回固定 owner */
      }
      return 'harmony-terminal';
    }

    /** tab 的内容区：一块透明的 stage，矩形变化就回报给壳层。 */
    function Stage(props) {
      const owner = tabOwner(props);
      const ownerRef = React.useRef(owner);
      ownerRef.current = owner;
      const stage = React.useRef(null);
      const opened = React.useRef(false);

      React.useEffect(() => {
        const element = stage.current;
        if (element === null) return undefined;
        let last = '';

        const report = function () {
          const rect = element.getBoundingClientRect();
          // 收起侧栏时 tab 的 body 还挂着，但矩形已经移出视口（或被 display:none
          // 压成 0）。这种情况只隐藏壳层视图，会话不动——重新展开时再铺回来。
          const inViewport = rect.bottom > 0 && rect.right > 0
            && rect.left < window.innerWidth && rect.top < window.innerHeight;
          const visible = document.visibilityState !== 'hidden' && inViewport
            && rect.width > 1 && rect.height > 1;
          const signature = [Math.round(rect.left), Math.round(rect.top),
            Math.round(rect.width), Math.round(rect.height), visible ? 1 : 0].join(',');
          // 收起/展开侧栏是「位置变了、尺寸没变」，ResizeObserver 不会触发；
          // 只在签名变化时发，避免每 300ms 刷一条控制台消息。
          if (signature === last) return;
          last = signature;
          send('bounds', {
            owner: ownerRef.current,
            left: rect.left,
            top: rect.top,
            width: rect.width,
            height: rect.height,
            visible: visible,
          });
        };
        const observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(report);
        if (observer !== null) observer.observe(element);
        window.addEventListener('resize', report);
        document.addEventListener('visibilitychange', report);
        if (window.visualViewport) {
          window.visualViewport.addEventListener('resize', report);
          window.visualViewport.addEventListener('scroll', report);
        }
        // 先 open 再报矩形：壳层拿到矩形才把视图铺开，open 只负责建会话。
        send('open', { owner: ownerRef.current, cols: 80, rows: 24 });
        opened.current = true;
        report();
        const timer = window.setInterval(report, 300);
        const raf = window.requestAnimationFrame(report);

        return function () {
          window.clearInterval(timer);
          window.cancelAnimationFrame(raf);
          if (observer !== null) observer.disconnect();
          window.removeEventListener('resize', report);
          document.removeEventListener('visibilitychange', report);
          if (window.visualViewport) {
            window.visualViewport.removeEventListener('resize', report);
            window.visualViewport.removeEventListener('scroll', report);
          }
        };
      }, []);

      // tab 关闭/页面卸载：只关壳层的视图并停会话，页面本身不做清理。
      React.useEffect(function () {
        return function () {
          send('close', { owner: ownerRef.current });
        };
      }, []);

      React.useEffect(function () {
        if (opened.current) send('focus', { owner: ownerRef.current });
      }, []);

      return h('div', {
        ref: stage,
        'data-harmony-terminal-stage': '',
        style: { position: 'absolute', inset: 0, overflow: 'hidden' },
      });
    }

    return {
      inject: ['slots', 'sidebarRight', 'sidebarRightTabs'],
      apply(ctx) {
        window.__dshHarmonyTerminalApply = true;
        try {
        ctx.effect(function () {
          return ctx.sidebarRightTabs.register({
            id: TAB_ID,
            kind: TAB_KIND,
            priority: 'extension',
            multiple: true,
            // 收起侧栏时保留 tab 的 body：会话要继续跑，只有 × 才停止。
            keepMounted: true,
            title: function () { return '终端'; },
            guide: [{
              id: 'new',
              order: 20,
              title: function () { return '原生终端'; },
              description: function () { return '在侧栏运行 shell，画面由系统原生绘制'; },
            }],
          });
        }, 'harmony-terminal.type');


        // × 关闭 tab：告诉壳层停止会话（这是唯一的停止入口）。
        ctx.effect(function () {
          return ctx.sidebarRight.registerCloseHandler(TAB_KIND, function (sessionId, tab) {
            send('close', { owner: tab && tab.id !== undefined ? String(tab.id) : 'harmony-terminal' });
          });
        }, 'harmony-terminal.close');

        ctx.effect(function () {
          return ctx.slots.inject('sidebar.right.pane.tab', function () {
            return ctx.slots.register({
              name: 'sidebar.right.pane.tab',
              key: TAB_ID,
            }, Stage);
          });
        }, 'harmony-terminal.body');

        // 系统返回键由壳层转到页面：收起右侧栏，终端会话不动。用服务判断/收起，
        // 不依赖按语言变化的 aria-label。
        window.__dshCollapseRightSidebar = function () {
          try {
            if (ctx.sidebarRight && ctx.sidebarRight.isExpanded && ctx.sidebarRight.isExpanded()) {
              ctx.sidebarRight.toggleExpanded();
              return true;
            }
          } catch (error) { /* 服务未就绪 */ }
          return false;
        };
        window.__dshHarmonyTerminalReady = true;
        } catch (error) {
          window.__dshHarmonyTerminalError = String(error && error.stack || error);
          throw error;
        }
      },
    };
  },
});
