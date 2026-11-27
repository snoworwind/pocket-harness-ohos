/**
 * 原生终端：DSH 右侧栏里的一个 dock tab，终端画面由鸿蒙壳层绘制。
 *
 * 分工（与 pocket-harness 相同的边界）：
 *  - 本插件只注册 tab、渲染一块透明的 stage，并把 stage 的矩形上报给壳层；
 *  - 壳层在这块矩形上铺自己的终端视图，会话、PTY、键盘都归壳层；
 *  - tab 的 × 触发 close 处理器，壳层据此停止会话。
 *
 * 页面 → 壳层没有 JS 桥对象可用，走
 * `console.log('DSH_TERM:<nonce>:' + json)`，nonce 由壳层在文档起点注入，
 * 壳层用 Web 组件的 onConsole 接收并校验。
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
    // 壳层只有一路原生终端（一个 PTY + 一块 libvterm 画面），所以所有桥消息
    // 都用固定 owner：标签 id 由页面内核生成，随版本/恢复策略变化，不能当键用。
    const OWNER = TAB_ID;

    function send(op, payload) {
      try {
        // 只允许主框架上报：预览/内置浏览器里的子框架不应驱动壳层终端。
        if (window.top !== window) return;
        // 壳层只接受带本次启动 nonce 的桥消息；nonce 由壳层在文档起点注入。
        const nonce = window.__dshNonce;
        if (typeof nonce !== 'string' || nonce === '') return;
        console.log('DSH_TERM:' + nonce + ':' + JSON.stringify(Object.assign({ op: op }, payload)));
      } catch (error) {
        /* 控制台不可用时静默：终端本身仍然可用 */
      }
    }

    /** 当前打开的会话 id（DSH 会话视图会把它写在 data-conversation-session 上）。 */
    function activeSessionId() {
      try {
        const el = document.querySelector('[data-conversation-session]');
        return el === null ? '' : (el.getAttribute('data-conversation-session') || '');
      } catch (error) {
        return '';
      }
    }

    /** 拉取会话列表；cwd 就是该会话的工作目录（项目目录）。 */
    async function fetchSessionItems() {
      try {
        const rpcId = (typeof crypto !== 'undefined' && crypto.randomUUID)
          ? crypto.randomUUID()
          : String(Date.now()) + Math.random().toString(16).slice(2);
        const response = await fetch('/api/session/list', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            type: 'client-request',
            rpcId: rpcId,
            method: 'session/list',
            payload: { args: { _request: {} } },
          }),
        });
        const data = await response.json();
        const items = data && data.result && data.result.value && data.result.value.items;
        return Array.isArray(items) ? items : [];
      } catch (error) {
        return [];
      }
    }

    function cwdOf(item) {
      if (!item) return '';
      return item.cwd
        || (item.projections && item.projections.values && item.projections.values.workingDirectory)
        || '';
    }

    /** 当前会话的工作目录：优先按当前打开的会话 id 匹配，退回归最近更新的会话。 */
    async function activeSessionCwd() {
      const items = await fetchSessionItems();
      if (items.length === 0) return '';
      const id = activeSessionId();
      const match = id === '' ? null : items.find(function (item) { return item.sessionId === id; });
      if (match) return cwdOf(match);
      const sorted = items.slice().sort(function (a, b) { return (b.updatedAt || 0) - (a.updatedAt || 0); });
      return cwdOf(sorted[0]);
    }

    /** 会话/工作区切换时把终端的 cwd 跟过去。 */
    function watchActiveSession() {
      if (window.__dshActiveSessionWatch) return;
      window.__dshActiveSessionWatch = true;
      let lastId = '';
      window.setInterval(function () {
        const id = activeSessionId();
        if (id === '' || id === lastId) return;
        lastId = id;
        activeSessionCwd().then(function (cwd) {
          if (cwd) send('cwd', { owner: OWNER, cwd: cwd });
        });
      }, 1200);
    }

    /** tab 的内容区：一块透明的 stage，矩形变化就回报给壳层。 */
    function Stage(props) {
      const ownerRef = React.useRef(OWNER);
      ownerRef.current = OWNER;
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
        // 解析当前会话的工作目录后补发：终端会落在项目目录（而不是固定目录）。
        activeSessionCwd().then(function (cwd) {
          if (cwd) send('cwd', { owner: ownerRef.current, cwd: cwd });
        });
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
        if (opened.current) {
          send('focus', { owner: ownerRef.current });
          // 切回终端时重新对齐会话目录（用户可能已经切了项目）。
          activeSessionCwd().then(function (cwd) {
            if (cwd) send('cwd', { owner: ownerRef.current, cwd: cwd });
          });
        }
      }, []);

      return h('div', {
        ref: stage,
        'data-harmony-terminal-stage': '',
        style: { position: 'absolute', inset: 0, overflow: 'hidden' },
      });
    }

    // 浏览器视图由壳层持有；切换 tab 仅隐藏，不应销毁或重新导航。
    function BrowserStage(props) {
      // Slot 提供的 action 绑定具体 session 和 tab，不能用当前会话的全局导航代替。
      const info = props.useTabInfo();
      const actions = React.useRef(info.tab.actions);
      actions.current = info.tab.actions;
      const stage = React.useRef(null);
      React.useEffect(function () {
        const element = stage.current;
        if (!element) return undefined;
        let last = '';
        function report() {
          const rect = element.getBoundingClientRect();
          const visible = document.visibilityState !== 'hidden' && rect.width > 1 && rect.height > 1
            && rect.bottom > 0 && rect.right > 0 && rect.left < window.innerWidth && rect.top < window.innerHeight;
          // 主 GUI 的会话标签是不可信数据，不是认证凭据；变化也必须上报。
          const sessionId = activeSessionId();
          const signature = JSON.stringify([rect.left, rect.top, rect.width, rect.height, visible, sessionId]);
          if (signature === last) return;
          last = signature;
          send('browserBounds', { left: rect.left, top: rect.top, width: rect.width, height: rect.height, visible: visible, sessionId: sessionId });
        }
        const observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(report);
        if (observer) observer.observe(element);
        window.addEventListener('resize', report);
        document.addEventListener('visibilitychange', report);
        if (window.visualViewport) {
          window.visualViewport.addEventListener('resize', report);
          window.visualViewport.addEventListener('scroll', report);
        }
        const nativeClosed = function () { actions.current.close(); };
        window.__dshBrowserClosed = nativeClosed;
        send('browserOpen', {});
        report();
        const timer = window.setInterval(report, 300);
        const raf = window.requestAnimationFrame(report);
        return function () {
          window.clearInterval(timer);
          window.cancelAnimationFrame(raf);
          if (observer) observer.disconnect();
          window.removeEventListener('resize', report);
          document.removeEventListener('visibilitychange', report);
          if (window.visualViewport) {
            window.visualViewport.removeEventListener('resize', report);
            window.visualViewport.removeEventListener('scroll', report);
          }
          if (window.__dshBrowserClosed === nativeClosed) delete window.__dshBrowserClosed;
          send('browserVisible', { visible: false });
        };
      }, []);
      return h('div', { ref: stage, 'data-harmony-browser-stage': '',
        style: { position: 'absolute', inset: 0, overflow: 'hidden' } });
    }

    /* ------------------------------------------------------------------ */
    /* 关于（设置里的一个分区）                                             */
    /* ------------------------------------------------------------------ */
    const PROJECT_URL = 'https://github.com/snoworwind/pocket-harness-ohos';
    const DSH_URL = 'https://github.com/deepseek-ai/deepseek-harness';

    function openUrl(url) {
      // 交给壳层用系统浏览器打开：应用内 WebView 不承载外部站点。
      send('openExternal', { url: url });
    }

    function AboutRow(props) {
      return h('button', {
        type: 'button',
        onClick: function () { openUrl(props.url); },
        style: {
          display: 'flex', flexDirection: 'column', alignItems: 'flex-start', gap: 2,
          width: '100%', padding: '10px 12px', marginBottom: 8, textAlign: 'left',
          borderRadius: 10, border: '1px solid var(--dsw-alias-border-l3)',
          background: 'transparent', color: 'var(--dsw-alias-label-primary)',
          font: 'inherit', cursor: 'pointer',
        },
      },
      h('span', { style: { fontSize: 13 } }, props.title),
      h('span', { style: { fontSize: 11, color: 'var(--dsw-alias-label-tertiary)', wordBreak: 'break-all' } }, props.url));
    }

    function AboutSection() {
      const rows = [
        ['本项目仓库', PROJECT_URL],
        ['DeepSeek Harness 仓库', DSH_URL],
        ['第三方软件声明 THIRD_PARTY_NOTICES.md', PROJECT_URL + '/blob/main/THIRD_PARTY_NOTICES.md'],
        ['许可证全文 LICENSES/', PROJECT_URL + '/tree/main/LICENSES'],
        ['GNU Bash 5.3 源码（GPL-3.0 对应源码）', 'https://ftp.gnu.org/gnu/bash/bash-5.3.tar.gz'],
      ];
      return h('div', { style: { display: 'flex', flexDirection: 'column', gap: 4, padding: '4px 0' } },
        h('h2', { style: { margin: '0 0 4px', fontSize: 16, fontWeight: 600 } }, '关于 · 鸿蒙原生版'),
        h('p', { style: { margin: '0 0 10px', fontSize: 12, lineHeight: 1.6, color: 'var(--dsw-alias-label-secondary)' } },
          '本项目由社区维护，与 DeepSeek 没有隶属、赞助或背书关系。界面与引擎来自官方 DeepSeek Harness（MIT）；终端、进程与应用运行时由本项目的鸿蒙原生层提供。'),
        rows.map(function (row) {
          return h(AboutRow, { key: row[1], title: row[0], url: row[1] });
        }),
        h('p', { style: { margin: '8px 0 0', fontSize: 11, lineHeight: 1.6, color: 'var(--dsw-alias-label-tertiary)' } },
          '许可证原文随安装包分发，首次启动后解出到应用沙箱的 files/notices/ 目录；仓库内的同名文件与之一致。第三方组件清单与各自许可见 THIRD_PARTY_NOTICES.md。'));
    }

    return {
      inject: ['slots', 'sidebarRight', 'sidebarRightTabs'],
      apply(ctx) {
        window.__dshHarmonyTerminalApply = true;
        // A request only selects the tab for the already visible session. It
        // cannot navigate or authorize a browser operation.
        window.__dshOpenAgentBrowser = function (sessionId) {
          if (typeof sessionId !== 'string' || sessionId !== activeSessionId()) return false;
          // Remember the request without expanding the sidebar. When the user
          // opens it, select the existing native browser instance.
          window.__dshPendingAgentBrowser = sessionId;
          return true;
        };
        const revealPendingBrowser = window.setInterval(function () {
          const sessionId = window.__dshPendingAgentBrowser;
          if (!sessionId || sessionId !== activeSessionId()) return;
          const toggle = document.querySelector('[aria-label="收起右侧边栏"]');
          if (!toggle || getComputedStyle(toggle).visibility === 'hidden' || !toggle.getBoundingClientRect().width) return;
          delete window.__dshPendingAgentBrowser;
          ctx.sidebarRight.openTabIn(sessionId, 'browser-harmony');
        }, 300);
        ctx.effect(function () { return function () { window.clearInterval(revealPendingBrowser); }; }, 'harmony-browser.pending');
        try {
        ctx.effect(function () {
          return ctx.sidebarRightTabs.register({
            id: TAB_ID,
            kind: TAB_KIND,
            priority: 'extension',
            // 壳层只有一路原生终端：multiple:false 让内核只保留一个 tab，
            // 点「原生终端」只会聚焦已有 tab，不会出现多个标签共用一个画面、
            // 关掉其中一个把另一个也弄没的情况。
            multiple: false,
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
          return ctx.sidebarRight.registerCloseHandler(TAB_KIND, function () {
            send('close', { owner: OWNER });
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

        ctx.effect(function () {
          return ctx.sidebarRightTabs.register({
            id: 'harmony-native-browser', kind: 'browser-harmony', priority: 'extension',
            multiple: false, keepMounted: false,
            title: function () { return '共享浏览器'; },
            guide: [{ id: 'new', order: 21, title: function () { return '共享浏览器'; },
              description: function () { return '各会话共用同一个原生浏览器和页面'; } }],
          });
        }, 'harmony-browser.type');
        ctx.effect(function () {
          return ctx.sidebarRight.registerCloseHandler('browser-harmony', function () {
            send('browserClose', {});
          });
        }, 'harmony-browser.close');
        ctx.effect(function () {
          return ctx.slots.inject('sidebar.right.pane.tab', function () {
            return ctx.slots.register({ name: 'sidebar.right.pane.tab', key: 'harmony-native-browser' }, BrowserStage);
          });
        }, 'harmony-browser.body');

        // 设置里的「关于」：仓库、上游、许可证与源码入口。
        ctx.effect(function () {
          return ctx.slots.inject('settings.section', function () {
            return ctx.slots.register({
              name: 'settings.section',
              id: 'harmony-about',
              order: 100,
              label: function () { return '关于'; },
            }, AboutSection);
          });
        }, 'harmony-terminal.about');

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
        watchActiveSession();
        } catch (error) {
          window.__dshHarmonyTerminalError = String(error && error.stack || error);
          throw error;
        }
      },
    };
  },
});
