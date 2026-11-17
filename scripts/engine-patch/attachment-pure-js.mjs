#!/usr/bin/env node
// 给随包引擎的 @deepseek-ai/dsh-attachment-local 追加纯 JS 图片降级实现。
//
//   node scripts/engine-patch/attachment-pure-js.mjs <node_modules/.../lib/index.js>
//
// 背景见 attachment-pure-js.epilogue.js 和 issue #1：鸿蒙上没有 sharp 原生模块，
// 也没有可用的 WASM，图片附件的入场校验/规范化/请求投影都会直接失败。
//
// 应用方式是「在文件末尾追加一段重新赋值函数声明的脚本」，而不是改写原实现：
// 引擎升级后只要这几个函数还叫原名，补丁就继续有效；名字变了会直接报错而不是
// 悄悄生成一个没打上补丁的归档。
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const PATCH_MARKER = '/* pocket-harness-ohos: attachment pure-JS fallback v1 */';
const REPLACED_FUNCTIONS = ['probeImage', 'detectImage', 'normalizeImage', 'createRequestImage', 'ensureDurableDirectory'];

/**
 * Append the fallback epilogue to one attachment-local module source.
 * @param {string} source - unpatched `lib/index.js` contents.
 * @returns {{ source: string, changed: boolean }} patched source and whether it was modified.
 */
export function applyAttachmentPatch(source) {
  if (source.includes(PATCH_MARKER)) return { source, changed: false };
  for (const name of REPLACED_FUNCTIONS) {
    if (!new RegExp(`\\bfunction\\s+${name}\\s*\\(`).test(source)) {
      throw new Error(
        `attachment patch: ${name}() not found; @deepseek-ai/dsh-attachment-local changed and the fallback needs review`
      );
    }
  }
  if (!/\bexport\s*\{/.test(source)) {
    throw new Error('attachment patch: no export block found; not an ES module we recognize');
  }
  const epilogue = readFileSync(join(here, 'attachment-pure-js.epilogue.js'), 'utf8');
  if (!epilogue.includes(PATCH_MARKER)) {
    throw new Error('attachment patch: epilogue is missing its marker');
  }
  return { source: `${source.replace(/\s*$/, '')}\n\n${epilogue}`, changed: true };
}

if (process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const target = process.argv[2];
  if (target === undefined) {
    console.error('usage: node scripts/engine-patch/attachment-pure-js.mjs <path-to-dsh-attachment-local/lib/index.js>');
    process.exit(2);
  }
  const file = resolve(target);
  const result = applyAttachmentPatch(readFileSync(file, 'utf8'));
  if (!result.changed) {
    console.log(`attachment patch: already applied (${file})`);
  } else {
    writeFileSync(file, result.source);
    console.log(`attachment patch: applied (${file})`);
  }
}
