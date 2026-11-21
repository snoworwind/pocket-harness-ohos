import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import z from "@deepseek-ai/schemastery";
import { dshHomePath } from "@deepseek-ai/dsh-home-paths";

/**
 * HarmonyOS adaptation — Host half.
 *
 * DeepSeek Harness 0.2.2-rc.1 has no `settings.register(namespace, schema)`
 * call: the settings document is a projection of every active profile entry's
 * exported `Config` schema, keyed by the profile entry id
 * (`@deepseek-ai/dsh-settings/lib/index.js`, `SettingsForms.describe()`).
 * This package's profile entry id is `harmony-native`, so its settings
 * namespace is `harmony-native` and its single volatile field is `keepAlive`.
 *
 * The value is mirrored to `$DSH_HOME/harmony-native.json` on mount and after
 * every accepted live edit, so the HarmonyOS application shell can poll it.
 * The write is atomic: a sibling `.tmp` file is renamed over the target.
 *
 * @module @deepseek-ai/dsh-harmony-compat
 */

/** Stable Cordis plugin name. */
export const name = "harmony-compat";

/** No required services: the optional settings presentation injects on demand. */
export const inject = [];

/** Mirrored file name inside the resolved harness home. */
export const MIRROR_FILENAME = "harmony-native.json";

/**
 * Live preference. `.volatile()` is what makes the field editable without
 * remounting the plugin and what `SettingsForms.describe()` projects into a
 * browser form: schemastery replaces the parsed value with a frozen
 * `{ get() }` reference that the Loader commits into in place.
 */
export const Config = z.object({
	keepAlive: z.boolean().default(false).volatile(),
	showSystemBars: z.boolean().default(false).volatile()
});

/**
 * Read a boolean field that may be a volatile `{ get }` reference.
 * @param config - parsed plugin Config.
 * @param key - field name.
 * @param fallback - value used when the field is absent.
 * @returns the accepted boolean.
 */
function booleanOf(config, key, fallback) {
	const value = config?.[key];
	if (typeof value?.get === "function") return value.get() === true;
	if (typeof value === "boolean") return value;
	return fallback;
}

/**
 * Read the current keep-alive value from the possibly-volatile Config field.
 * @param config - parsed plugin Config.
 * @returns the accepted boolean, defaulting to the enabled state.
 */
function keepAliveOf(config) {
	return booleanOf(config, "keepAlive", true);
}

/**
 * Mount the mirror: write once at startup, then again whenever the Loader
 * commits a new volatile value for this plugin (`loader/volatile-update` is
 * emitted on this fiber's context by `cordis-plugin-loader`).
 * @param ctx - Host plugin context.
 * @param config - parsed plugin Config whose `keepAlive` is a volatile ref.
 */
export function apply(ctx, config) {
	const file = dshHomePath(MIRROR_FILENAME);
	/** Serialized writes so two quick edits cannot interleave their temp files. */
	let tail = Promise.resolve();

	const mirror = () => {
		const keepAlive = keepAliveOf(config);
		const showSystemBars = booleanOf(config, "showSystemBars", false);
		tail = tail.then(async () => {
			// 应用壳层还会往同一文件写 autoReview 等开关；这里只更新本插件
			// 负责的字段，必须保留其它字段，否则插件一挂载就把手工/未来的设置冲掉。
			let previous = {};
			try {
				const parsed = JSON.parse(await readFile(file, "utf8"));
				if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) previous = parsed;
			} catch (error) {
				/* 首次写入或文件损坏：按空对象处理 */
			}
			const body = JSON.stringify({ ...previous, keepAlive, showSystemBars });
			await mkdir(dirname(file), { recursive: true });
			const temporary = `${file}.${process.pid}.tmp`;
			await writeFile(temporary, body, "utf8");
			await rename(temporary, file);
		}).catch((error) => {
			ctx.logger?.warn?.(error);
		});
		return tail;
	};

	mirror();
	ctx.on("loader/volatile-update", (paths) => {
		if (!Array.isArray(paths)) return;
		// keepAlive 与 showSystemBars 都镜像给应用壳层。
		if (!paths.some((path) => Array.isArray(path) && (path[0] === "keepAlive" || path[0] === "showSystemBars"))) return;
		mirror();
	});

	// 不再调用 settings.configure({auto:false})：那样会把命名空间标成「已呈现」，
	// 客户端拿到的表单变成只读，开关点了不生效。保留自动生成的插件配置页不影响。

}
