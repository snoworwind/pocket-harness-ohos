window.__ModuleLoader__.load({
	id: "@deepseek-ai/dsh-harmony-compat",
	factory: (require) => {
		var module = { exports: {} };
		// #region harmony-compat: 平台 UI 适配
		// 这些是给鸿蒙壳层用的页面适配：浮层状态上报（返回手势）和
		// 选区「引用文本」浮层位置修正。与终端 tab 无关，放在适配插件里。
		(function installHarmonyUiCompat() {
			const bridge = function (op, payload) {
				try {
					if (window.top !== window) return;
					const nonce = window.__dshNonce;
					if (typeof nonce !== 'string' || nonce === '') return;
					console.log('DSH_TERM:' + nonce + ':' + JSON.stringify(Object.assign({ op: op }, payload)));
				} catch (error) { /* 控制台不可用 */ }
			};

			function watchOverlays() {
				if (window.__dshOverlayWatch) return;
				window.__dshOverlayWatch = true;
				let last = '';
				const sample = function () {
					try {
						const drawer = document.querySelector('[role=dialog][aria-label="导航"]');
						const nav = drawer !== null && drawer.getAttribute('aria-modal') === 'true';
						const dialog = document.querySelector('[role=dialog]:not([aria-label="导航"])') !== null;
						const menu = document.querySelector('[role=menu]') !== null;
						const collapse = document.querySelector('[aria-label="收起右侧边栏"]');
						const right = collapse !== null && window.getComputedStyle(collapse).visibility !== 'hidden'
							&& collapse.getBoundingClientRect().width > 0;
						const state = JSON.stringify({ nav: nav, dialog: dialog, menu: menu, right: right });
						if (state !== last) {
							last = state;
							bridge('ui', { nav: nav, dialog: dialog, menu: menu, right: right });
						}
					} catch (error) { /* 页面结构变化时静默 */ }
				};
				const observer = new MutationObserver(sample);
				observer.observe(document.documentElement, {
					subtree: true,
					childList: true,
					attributes: true,
					attributeFilter: ['aria-modal', 'aria-expanded', 'aria-hidden', 'class', 'style', 'role'],
				});
				window.setInterval(sample, 300);
				sample();
			}

			function installQuoteToolbarFix() {
				if (window.__dshQuoteToolbarFix) return;
				window.__dshQuoteToolbarFix = true;
				const place = function () {
					try {
						const button = document.querySelector('button[aria-label="引用文本"]');
						if (button === null) return;
						const selection = window.getSelection();
						if (selection === null || selection.rangeCount === 0 || selection.isCollapsed) return;
						const rect = selection.getRangeAt(0).getBoundingClientRect();
						if (rect.width === 0 && rect.height === 0) return;
						let node = button;
						while (node !== null && node !== document.body) {
							const style = window.getComputedStyle(node);
							if (style.position === 'fixed' || style.position === 'absolute') break;
							node = node.parentElement;
						}
						if (node === null || node === document.body) return;
						// 浮层的 top/left 相对 offsetParent（消息列），不能直接用视口坐标。
						const parent = node.offsetParent || node.parentElement;
						if (parent === null) return;
						const parentRect = parent.getBoundingClientRect();
						const width = node.offsetWidth || button.offsetWidth;
						const height = node.offsetHeight || 32;
						const gap = 8;
						let top;
						if (rect.bottom + gap + height <= window.innerHeight) {
							top = rect.bottom + gap - parentRect.top;
						} else {
							top = rect.top - gap - height - parentRect.top;
						}
						let left = rect.left + rect.width / 2 - parentRect.left - width / 2;
						left = Math.max(4, Math.min(parentRect.width - width - 4, left));
						node.style.setProperty('top', Math.round(top) + 'px', 'important');
						node.style.setProperty('left', Math.round(left) + 'px', 'important');
						node.style.setProperty('bottom', 'auto', 'important');
					} catch (error) { /* 页面结构变化时静默 */ }
				};
				['selectionchange', 'mouseup', 'touchend', 'scroll'].forEach(function (name) {
					document.addEventListener(name, function () {
						window.setTimeout(place, 60);
						window.setTimeout(place, 200);
					}, true);
				});
				window.addEventListener('resize', function () { window.setTimeout(place, 60); });
			}

			watchOverlays();
			installQuoteToolbarFix();
		})();
		// #endregion
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
		let react_jsx_runtime = require("react/jsx-runtime");
		let _deepseek_ai_dsh_client_ui_primitives = require("@deepseek-ai/dsh-client-ui-primitives");
		//#region @deepseek-ai/dsh-harmony-compat/HarmonyRow.module.css
		const css = ".hmyCmp_row{border-bottom:.5px solid var(--dsw-alias-border-l2);justify-content:space-between;align-items:center;gap:24px;padding:16px 0;display:flex}.hmyCmp_title{color:var(--dsw-alias-label-primary);font-size:14px;font-weight:400;line-height:22px}.hmyCmp_description{color:var(--dsw-alias-label-secondary);margin-top:4px;font-size:12px;line-height:18px}";
		const tagId = "@deepseek-ai/dsh-harmony-compat/HarmonyRow.module.css";
		if (typeof document !== "undefined" && document.querySelector("style[data-plugin-css=" + JSON.stringify(tagId) + "]") === null) {
			const tag = document.createElement("style");
			tag.dataset.plugin = "@deepseek-ai/dsh-harmony-compat";
			tag.dataset.pluginCss = tagId;
			tag.textContent = css;
			document.head.appendChild(tag);
		}
		var HarmonyRow_module_css_default = {
			"description": "hmyCmp_description",
			"row": "hmyCmp_row",
			"title": "hmyCmp_title"
		};
		//#endregion
		//#region @deepseek-ai/dsh-harmony-compat/locales.js
		/** HarmonyOS adaptation copy, Chinese first. */
		const zh = {
			title: "鸿蒙适配 / 后台保活",
			description: "开启后，应用会在后台维持定位连续任务，降低被系统冻结的概率。",
			systemBarsTitle: "显示系统状态栏与底部手势条",
			systemBarsDescription: "关闭沉浸式全屏。开启后可以看到时间、电量与底部手势条，页面内容会整体让开这两条系统栏。"
		};
		/** English copy, checked against the Chinese keys. */
		const en = {
			title: "HarmonyOS adaptation / Background keep-alive",
			description: "Keep location-based continuous tasks running in the background so the system is less likely to freeze the app.",
			systemBarsTitle: "Show system status and navigation bars",
			systemBarsDescription: "Leave immersive full screen. Enabling this shows the clock, battery and gesture bar, and the page is inset below them."
		};
		//#endregion
		//#region @deepseek-ai/dsh-harmony-compat/HarmonyRow.js
		/**
		* One settings row: localized title and description on the left, one switch
		* bound to a Host Config boolean field on the right.
		* @param props - copy hook, config-form hook, field name, copy keys, writer.
		* @returns the settings row element tree.
		*/
		function HarmonySwitchRow({ t, useConfig, field, titleKey, descriptionKey, setValue }) {
			const state = useConfig((value) => value);
			return (0, react_jsx_runtime.jsxs)("div", {
				className: HarmonyRow_module_css_default.row,
				children: [(0, react_jsx_runtime.jsxs)("div", { children: [(0, react_jsx_runtime.jsx)("div", {
					className: HarmonyRow_module_css_default.title,
					children: t(titleKey)
				}), (0, react_jsx_runtime.jsx)("div", {
					className: HarmonyRow_module_css_default.description,
					children: t(descriptionKey)
				})] }), (0, react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.Switch, {
					checked: state.value?.[field] === true,
					label: t(titleKey),
					disabled: state.status !== "ready" || !state.writable,
					onChange: (enabled) => {
						setValue(enabled);
					}
				})]
			});
		}

		/** Keep-alive row (background location continuous task). */
		function HarmonyRow(props) {
			return (0, react_jsx_runtime.jsx)(HarmonySwitchRow, {
				t: props.t,
				useConfig: props.useConfig,
				field: "keepAlive",
				titleKey: "title",
				descriptionKey: "description",
				setValue: props.setKeepAlive
			});
		}

		/** System bars row (leave immersive full screen). */
		function SystemBarsRow(props) {
			return (0, react_jsx_runtime.jsx)(HarmonySwitchRow, {
				t: props.t,
				useConfig: props.useConfig,
				field: "showSystemBars",
				titleKey: "systemBarsTitle",
				descriptionKey: "systemBarsDescription",
				setValue: props.setShowSystemBars
			});
		}
		//#endregion
		//#region @deepseek-ai/dsh-harmony-compat/index.js
		/** Services used by the browser companion. */
		const inject = [
			"slots",
			"locale",
			"configForms"
		];
		/**
		* Register the keep-alive row into General settings while its Host
		* namespace is served. The namespace is the profile entry id, because the
		* Host settings document is a projection of active entry Config schemas.
		* @param ctx - browser plugin context.
		*/
		function apply(ctx) {
			const locale = "settings.harmony";
			const namespace = "harmony-native";
			ctx.effect(() => ctx.locale.register(locale, {
				zh,
				en
			}), "harmony-compat: settings copy");
			const form = ctx.configForms.get(namespace);
			const face = () => ({
				hooks: { config: form },
				setKeepAlive: (enabled) => {
					void form.set("keepAlive", enabled);
				}
			});
			const systemBarsFace = () => ({
				hooks: { config: form },
				setShowSystemBars: (enabled) => {
					void form.set("showSystemBars", enabled);
				}
			});
			ctx.effect(() => ctx.configForms.whileServed([namespace], () => ctx.slots.inject("settings.general.item", () => ctx.slots.register({
				name: "settings.general.item",
				id: namespace,
				order: 95,
				locale,
				inject: face
			}, HarmonyRow))), "harmony-compat: general settings row");
			// 显示状态栏/导航栏：与保活同一命名空间下的另一个开关。
			ctx.effect(() => ctx.configForms.whileServed([namespace], () => ctx.slots.inject("settings.general.item", () => ctx.slots.register({
				name: "settings.general.item",
				id: namespace + "-system-bars",
				order: 96,
				locale,
				inject: systemBarsFace
			}, SystemBarsRow))), "harmony-compat: system bars settings row");
		}
		//#endregion
		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});
