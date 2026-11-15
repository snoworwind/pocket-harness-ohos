window.__ModuleLoader__.load({
	id: "@deepseek-ai/dsh-harmony-compat",
	factory: (require) => {
		var module = { exports: {} };
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
			description: "开启后，应用会在后台维持定位连续任务，降低被系统冻结的概率。"
		};
		/** English copy, checked against the Chinese keys. */
		const en = {
			title: "HarmonyOS adaptation / Background keep-alive",
			description: "Keep location-based continuous tasks running in the background so the system is less likely to freeze the app."
		};
		//#endregion
		//#region @deepseek-ai/dsh-harmony-compat/HarmonyRow.js
		/**
		* Render the HarmonyOS keep-alive row: localized title and description on
		* the left, one switch bound to the Host `keepAlive` field on the right.
		* @param props - slot props: copy hook, config-form hook and writer.
		* @returns the settings row element tree.
		*/
		function HarmonyRow({ t, useConfig, setKeepAlive }) {
			const state = useConfig((value) => value);
			return (0, react_jsx_runtime.jsxs)("div", {
				className: HarmonyRow_module_css_default.row,
				children: [(0, react_jsx_runtime.jsxs)("div", { children: [(0, react_jsx_runtime.jsx)("div", {
					className: HarmonyRow_module_css_default.title,
					children: t("title")
				}), (0, react_jsx_runtime.jsx)("div", {
					className: HarmonyRow_module_css_default.description,
					children: t("description")
				})] }), (0, react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.Switch, {
					checked: state.value?.keepAlive === true,
					label: t("title"),
					disabled: state.status !== "ready" || !state.writable,
					onChange: (enabled) => {
						setKeepAlive(enabled);
					}
				})]
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
			ctx.effect(() => ctx.configForms.whileServed([namespace], () => ctx.slots.inject("settings.general.item", () => ctx.slots.register({
				name: "settings.general.item",
				id: namespace,
				order: 95,
				locale,
				inject: face
			}, HarmonyRow))), "harmony-compat: general settings row");
		}
		//#endregion
		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});
