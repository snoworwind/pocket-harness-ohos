/* pocket-harness-ohos: attachment pure-JS fallback v1 */
// 追加在 @deepseek-ai/dsh-attachment-local/lib/index.js 末尾，由
// scripts/engine-patch/attachment-pure-js.mjs 在打包时应用。
//
// 为什么需要：随包引擎按设计不含任何原生二进制（ship-from-dump.mjs 会剔掉
// prebuilds/ 与 *.node/*.so），而 ArkWeb 侧 Node 以 --jitless --no-expose-wasm
// 运行，sharp 的 WASM 兜底也起不来。附件包的入场校验、规范化和请求投影每一步
// 都 requireSharp()，所以图片附件必然失败。
//
// 这里的降级策略（与 issue #1 的方案 B.2 一致）：
//   * 只解析文件头（PNG IHDR / JPEG SOFn / WebP VP8X|VP8|VP8L / GIF LSD）；
//   * 跳过 sharp 的完整解码与重编码，原字节透传；
//   * 透传的上限由附件包的 maxImageBytes / maxImagePixels / maxImageDimension 把关；
//   * 代价：不做 EXIF 旋转、2048² 降采样与 8-bit sRGB 归一化，超大图也不会缩。
//
// 以「重新赋值函数声明」的方式覆盖实现，不重写原文件：函数声明是模块级可变绑定，
// 模块内其它函数（inspectMetadata / prepareImageFile / readImageFile / ...）
// 调用时读到的就是新实现，升级引擎时只要这些名字还在即可继续生效。

function __phAscii(data, start, length) {
	let out = "";
	for (let i = 0; i < length; i += 1) {
		const code = data[start + i];
		if (code === void 0) return void 0;
		out += String.fromCharCode(code);
	}
	return out;
}

function __phU16LE(data, at) {
	return data[at] | data[at + 1] << 8;
}

function __phU24LE(data, at) {
	return (data[at] | data[at + 1] << 8 | data[at + 2] << 16) >>> 0;
}

function __phU32LE(data, at) {
	return (data[at] | data[at + 1] << 8 | data[at + 2] << 16 | data[at + 3] << 24) >>> 0;
}

function __phU32BE(data, at) {
	return (data[at] << 24 | data[at + 1] << 16 | data[at + 2] << 8 | data[at + 3]) >>> 0;
}

/** PNG: signature + 首块必须是 IHDR；metadata 由 iCCP/eXIf/tEXt/zTXt/iTXt 块声明。 */
function __phParsePng(data) {
	const signature = [137, 80, 78, 71, 13, 10, 26, 10];
	if (data.length < 33) return null;
	for (let i = 0; i < signature.length; i += 1) {
		if (data[i] !== signature[i]) return null;
	}
	if (__phU32BE(data, 8) !== 13 || __phAscii(data, 12, 4) !== "IHDR") return null;
	const width = __phU32BE(data, 16);
	const height = __phU32BE(data, 20);
	if (width === 0 || height === 0) return null;
	const bitDepth = data[24];
	const colourType = data[25];
	let hasAlpha = colourType === 4 || colourType === 6;
	let carriesMetadata = false;
	let at = 8;
	while (at + 12 <= data.length) {
		const length = __phU32BE(data, at);
		const type = __phAscii(data, at + 4, 4);
		if (type === void 0) return null;
		if (type === "IEND") break;
		if (type === "iCCP" || type === "eXIf" || type === "tEXt" || type === "zTXt" || type === "iTXt") carriesMetadata = true;
		if (type === "tRNS") hasAlpha = true;
		if (length > data.length - at - 12) return null;
		at += 12 + length;
	}
	return {
		mediaType: "image/png",
		width,
		height,
		animated: false,
		carriesMetadata,
		depth: bitDepth === 16 ? "ushort" : "uchar",
		space: "srgb",
		hasAlpha
	};
}

/** JPEG: 扫到 SOFn 取精度与宽高；APPn（EXIF/XMP/ICC）记作需要归一化的元数据。 */
function __phParseJpeg(data) {
	if (data.length < 4 || data[0] !== 0xff || data[1] !== 0xd8) return null;
	let at = 2;
	let carriesMetadata = false;
	while (at + 1 < data.length) {
		if (data[at] !== 0xff) {
			at += 1;
			continue;
		}
		const marker = data[at + 1];
		if (marker === 0xff) {
			at += 1;
			continue;
		}
		at += 2;
		if (marker === 0xd8 || marker === 0x01 || marker >= 0xd0 && marker <= 0xd7) continue;
		if (marker === 0xd9 || marker === 0xda) break;
		if (at + 2 > data.length) return null;
		const size = data[at] << 8 | data[at + 1];
		if (size < 2 || at + size > data.length) return null;
		const isStartOfFrame = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
		if (isStartOfFrame) {
			if (size < 7) return null;
			const precision = data[at + 2];
			const height = data[at + 3] << 8 | data[at + 4];
			const width = data[at + 5] << 8 | data[at + 6];
			if (width === 0 || height === 0) return null;
			return {
				mediaType: "image/jpeg",
				width,
				height,
				animated: false,
				carriesMetadata,
				depth: precision === 8 ? "uchar" : "ushort",
				space: "srgb",
				hasAlpha: false
			};
		}
		if (marker >= 0xe0 && marker <= 0xef) carriesMetadata = true;
		at += size;
	}
	return null;
}

/** WebP: 优先读 VP8X 画布；简单格式退回 VP8（有损）或 VP8L（无损）头。 */
function __phParseWebp(data) {
	if (data.length < 20 || __phAscii(data, 0, 4) !== "RIFF" || __phAscii(data, 8, 4) !== "WEBP") return null;
	let at = 12;
	while (at + 8 <= data.length) {
		const type = __phAscii(data, at, 4);
		const size = __phU32LE(data, at + 4);
		const body = at + 8;
		if (body + size > data.length) return null;
		if (type === "VP8X") {
			if (size < 10) return null;
			const flags = data[body];
			const width = __phU24LE(data, body + 4) + 1;
			const height = __phU24LE(data, body + 7) + 1;
			if (width === 0 || height === 0) return null;
			return {
				mediaType: "image/webp",
				width,
				height,
				animated: (flags & 0x02) !== 0,
				carriesMetadata: (flags & 0x2c) !== 0,
				depth: "uchar",
				space: "srgb",
				hasAlpha: (flags & 0x10) !== 0
			};
		}
		if (type === "VP8 ") {
			if (size < 10 || data[body + 3] !== 0x9d || data[body + 4] !== 0x01 || data[body + 5] !== 0x2a) return null;
			const width = (data[body + 6] | data[body + 7] << 8) & 0x3fff;
			const height = (data[body + 8] | data[body + 9] << 8) & 0x3fff;
			if (width === 0 || height === 0) return null;
			return {
				mediaType: "image/webp",
				width,
				height,
				animated: false,
				carriesMetadata: false,
				depth: "uchar",
				space: "srgb",
				hasAlpha: false
			};
		}
		if (type === "VP8L") {
			if (size < 5 || data[body] !== 0x2f) return null;
			const bits = __phU32LE(data, body + 1);
			const width = (bits & 0x3fff) + 1;
			const height = (bits >>> 14 & 0x3fff) + 1;
			return {
				mediaType: "image/webp",
				width,
				height,
				animated: false,
				carriesMetadata: false,
				depth: "uchar",
				space: "srgb",
				hasAlpha: (bits >>> 28 & 0x01) === 1
			};
		}
		at = body + size + (size & 1);
	}
	return null;
}

/** GIF: 逻辑屏幕宽高；数一数图形控制扩展判断是否多帧、是否有透明色。 */
function __phParseGif(data) {
	const signature = __phAscii(data, 0, 6);
	if (signature !== "GIF87a" && signature !== "GIF89a") return null;
	if (data.length < 13) return null;
	const width = __phU16LE(data, 6);
	const height = __phU16LE(data, 8);
	if (width === 0 || height === 0) return null;
	let frames = 0;
	let hasAlpha = false;
	for (let i = 0; i + 3 < data.length; i += 1) {
		if (data[i] === 0x21 && data[i + 1] === 0xf9 && data[i + 2] === 0x04) {
			frames += 1;
			if ((data[i + 3] & 0x01) !== 0) hasAlpha = true;
		}
	}
	return {
		mediaType: "image/gif",
		width,
		height,
		animated: frames > 1,
		carriesMetadata: false,
		depth: "uchar",
		space: "srgb",
		hasAlpha
	};
}

// 鸿蒙应用沙箱不允许 open('/data/storage/el2')：附件落盘时 ensureDurableHome()
// 会从 DSH_HOME 一路 fsync 到文件系统根，碰到沙箱边界就 EACCES，导致所有附件
// （普通文件也一样）在真正写文件前就失败。到不可访问的边界即停止；边界以下仍逐级 fsync。
async function __phEnsureDurableDirectory(path, boundary) {
	const target = resolve(path);
	const stop = resolve(boundary);
	await mkdir(target, { recursive: true, mode: 448 });
	await chmod(target, 448);
	let level = target;
	while (level !== stop) {
		const parent = dirname(level);
		try {
			await syncDirectory(parent);
		} catch (error) {
			if (error?.code === "EACCES" || error?.code === "EPERM") return;
			throw error;
		}
		if (parent === level) return;
		level = parent;
	}
}

function __phParseImageHeader(data) {
	if (!(data instanceof Uint8Array) || data.byteLength === 0) return null;
	return __phParsePng(data) ?? __phParseJpeg(data) ?? __phParseWebp(data) ?? __phParseGif(data);
}

async function __phImageHeaderFacts(data, limits) {
	let detected = null;
	try {
		detected = __phParseImageHeader(data);
	} catch (error) {
		detected = null;
	}
	if (detected === null) throw new AttachmentError("Unsupported or malformed image data.", "INVALID_IMAGE");
	if (limits?.maxPixels !== void 0 && detected.width * detected.height > limits.maxPixels) throw new AttachmentError("Image exceeds the configured decoded-pixel limit.", "IMAGE_TOO_MANY_PIXELS");
	if (limits?.maxDimension !== void 0 && Math.max(detected.width, detected.height) > limits.maxDimension) throw new AttachmentError("Image exceeds the configured per-side pixel limit.", "IMAGE_DIMENSION_TOO_LARGE");
	return detected;
}

probeImage = async function probeImage(data) {
	return __phImageHeaderFacts(data);
};

detectImage = async function detectImage(data, limits) {
	return __phImageHeaderFacts(data, limits);
};

// 无编码器：不再重编码、降采样或做 EXIF 旋转，直接保存原始字节。
normalizeImage = async function normalizeImage(data, detected) {
	return {
		data,
		mediaType: detected.mediaType,
		width: detected.width,
		height: detected.height
	};
};

// 请求投影同样透传：目标尺寸/字节预算由上层路由决定，这里不再二次编码。
createRequestImage = async function createRequestImage(attachment) {
	return {
		data: attachment.data,
		mediaType: attachment.ref.mediaType,
		width: attachment.ref.width,
		height: attachment.ref.height
	};
};

ensureDurableDirectory = __phEnsureDurableDirectory;
