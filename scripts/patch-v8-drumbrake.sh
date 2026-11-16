#!/usr/bin/env bash
# patch-v8-drumbrake.sh — EXPERIMENTAL / NOT USABLE as of Node 24.22.1.
#
# Status: the DrumBrake sources bundled with this V8 snapshot are stale relative
# to the rest of V8 (about 50 compile errors in value-type/HeapType APIs), and
# V8 documents that the wasm interpreter still allocates executable memory at
# runtime, which conflicts with HarmonyOS's no-JIT policy. Kept as a record of
# the investigation; the supported path is harmony/fetch-polyfill.cjs.
#
# What it would do: let V8's Wasm interpreter (DrumBrake) build for OHOS so
# WebAssembly is available under --jitless and Node's undici fetch can work.
#
# Two build systems are involved:
#   - GN  (deps/v8/BUILD.gn + gni/v8.gni): upstream definition of the feature and
#     the target-OS allow-list. OHOS is a Linux/musl target, so add it.
#   - gyp (tools/v8_gypfiles/v8.gyp): the build Node actually uses. It scrapes
#     some source lists from BUILD.gn but not the `if (v8_enable_drumbrake)`
#     blocks, so the interpreter sources and the define must be added explicitly.
#
# Usage: scripts/patch-v8-drumbrake.sh <node source dir>
set -euo pipefail

SRC=${1:?usage: patch-v8-drumbrake.sh <node source dir>}
GNI="$SRC/deps/v8/gni/v8.gni"
BUILD="$SRC/deps/v8/BUILD.gn"
GYP="$SRC/tools/v8_gypfiles/v8.gyp"

[ -f "$GNI" ] && [ -f "$BUILD" ] && [ -f "$GYP" ] || { echo "not a Node source tree: $SRC" >&2; exit 1; }

python3 - "$GNI" "$BUILD" "$GYP" <<'PY'
import pathlib
import sys

gni = pathlib.Path(sys.argv[1])
build = pathlib.Path(sys.argv[2])
gyp = pathlib.Path(sys.argv[3])

# ---- GN: allow OHOS as a DrumBrake target ----
text = gni.read_text()
old = '(target_os == "win" || target_os == "linux" || target_os == "mac")'
new = ('(target_os == "win" || target_os == "linux" || target_os == "mac"'
       ' || target_os == "ohos")')
if 'target_os == "ohos"' not in text:
    if old not in text:
        raise SystemExit('is_drumbrake_supported pattern not found')
    gni.write_text(text.replace(old, new))

# ---- GN: turn the feature on (kept for consistency; gyp is what Node builds) ----
text = build.read_text()
if '\n  v8_enable_drumbrake = true\n' not in text:
    marker = '\n  v8_enable_drumbrake = false\n'
    if marker not in text:
        raise SystemExit('v8_enable_drumbrake pattern not found')
    build.write_text(text.replace(marker, '\n  v8_enable_drumbrake = true\n'))

# ---- gyp: define the macro for every V8 translation unit ----
text = gyp.read_text()
if 'V8_ENABLE_DRUMBRAKE' not in text:
    marker = "          'BUILDING_V8_PLATFORM_SHARED',  # Make V8_PLATFORM_EXPORT visible.\n"
    if marker not in text:
        raise SystemExit('v8.gyp defines marker not found')
    text = text.replace(marker, marker + "          'V8_ENABLE_DRUMBRAKE',\n")

    # ---- gyp: add the interpreter sources to v8_base_without_compiler ----
    start = text.index("'target_name': 'v8_base_without_compiler'")
    cond = text.index("      'conditions': [\n", start)
    inject = (
        "      'conditions': [\n"
        "        ['1==1', {\n"
        "          'sources': [\n"
        "            '<(V8_ROOT)/src/wasm/interpreter/wasm-interpreter.cc',\n"
        "            '<(V8_ROOT)/src/wasm/interpreter/wasm-interpreter-objects.cc',\n"
        "            '<(V8_ROOT)/src/wasm/interpreter/wasm-interpreter-runtime.cc',\n"
        "            '<(V8_ROOT)/src/wasm/interpreter/wasm-interpreter-simd.cc',\n"
        "          ],\n"
        "        }],\n"
        "        ['target_arch==\"x64\"', {\n"
        "          'sources': [\n"
        "            '<(V8_ROOT)/src/wasm/interpreter/x64/interpreter-builtins-x64.cc',\n"
        "          ],\n"
        "        }],\n"
        "        ['target_arch==\"arm64\"', {\n"
        "          'sources': [\n"
        "            '<(V8_ROOT)/src/wasm/interpreter/arm64/interpreter-builtins-arm64.cc',\n"
        "          ],\n"
        "        }],\n"
    )
    text = text[:cond] + inject + text[cond + len("      'conditions': [\n"):]
    gyp.write_text(text)
PY

echo "patched: $SRC"
grep -n 'target_os == "ohos"' "$GNI" | head -1
grep -n 'v8_enable_drumbrake = ' "$BUILD" | head -1
grep -n 'V8_ENABLE_DRUMBRAKE' "$GYP" | head -1
grep -n 'wasm-interpreter-runtime.cc' "$GYP" | head -1
