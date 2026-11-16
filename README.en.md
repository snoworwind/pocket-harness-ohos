# Pocket Harness · HarmonyOS Native Edition

English | [简体中文](README.md)

> **Unofficial project.** Maintained by the community; not affiliated with, sponsored by, or endorsed by DeepSeek. "DeepSeek", "DeepSeek Harness" and the whale logo belong to DeepSeek. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for licensing and third-party components.

This project packages the **official DeepSeek Harness** as a HarmonyOS app. The UI is the official web GUI (`dsh --profile web`); the agent loop, tool calls, approvals, sessions and workspaces come from `@deepseek-ai/dsh`. Node, Bash, toybox, libarchive and ripgrep are cross-compiled for `aarch64-linux-ohos` and shipped as native libraries inside the HAP — no adb, Termux or remote server required. The terminal is rendered natively with libvterm as a closable tab in the right sidebar.

| Item | Value |
| --- | --- |
| App name | Pocket Harness |
| Bundle | `com.snoworwind.phoh` |
| Version | `0.1.0.1` (versionCode 2) |
| Min / target API | HarmonyOS 5.1.0 (API 18) / API 24 |
| Engine | `@deepseek-ai/dsh` 0.2.2-rc.1 (web profile, 291 plugins) |
| Runtime | Node 24.22.1 (`--jitless`), Bash 5.3, toybox 0.8.14, libarchive 3.7.7, ripgrep 14.1.1 |
| Distribution | GitHub Release: unsigned HAP + arm64/x86_64 native libraries (**no AppGallery release is planned for now**) |

> This project is **not intended for Huawei AppGallery** for now. It is distributed only through
> GitHub Releases as an unsigned HAP plus prebuilt native libraries; users must sign it with their
> own debug certificate before installing. The `.app` packaging step below is kept only for a
> possible future store release.

## Features

- **Official web GUI**: agent loop, tools, approvals, sessions and workspaces are the upstream engine; the UI is not reimplemented.
- **Native terminal**: a closable right-sidebar tab with PTY and job control (`Ctrl-Z`, `fg`, `bg`), libvterm rendering, IME-aware layout and orientation support. It starts in the current DSH session's working directory and follows session/workspace switches.
- **Back gesture**: closes overlays in priority order — menu → settings dialog → right sidebar/terminal → left drawer → system. Collapsing the terminal keeps the process running; only the tab's × stops it.
- **Quote popover**: the "quote text" button is placed below the selection, clear of the system selection toolbar.
- **Pinch zoom disabled**: the layout is viewport-based; zoom would break terminal/sidebar geometry.
- **No JIT**: Node runs with `--jitless`, so undici's WASM-based fetch is unavailable; a pure-JS `fetch` polyfill is injected at runtime.
- **TLS trust**: Mozilla roots plus an optional `extra-ca.pem` (development HTTPS interception CA); certificates are always fully verified.

## Layout

```text
entry/src/main/ets
  ├─ pages/Index.ets             Web component, bridge messages, back gesture, boot states
  ├─ pages/Terminal.ets          libvterm view and PTY session
  └─ platform/NativeRuntime.ets  engine unpacking, dsh web, CA bundle, launchers

plugins/
  ├─ dsh-harmony-terminal/       terminal tab: registration, stage bounds, open/close/focus, cwd
  └─ harmony-compat/             HarmonyOS adaptation: overlay state, quote popover

native/
  ├─ iec/                        IEC execution core (from Bettersh): exec/tty/fs shims, ELF loader
  ├─ terminal/                   libvterm and terminal NAPI
  └─ toolchain/                  Node 24 / native addon OHOS toolchain

scripts/
  ├─ build.mjs                   HAP build (Windows/macOS/Linux, auto-detects DevEco)
  ├─ build-x86-runtime.sh        staged x86_64 emulator runtime build
  ├─ pack-native.sh              native libs + engine archive → entry/
  └─ test-fetch-polyfill.cjs     15 fetch-polyfill regression tests
```

## Building

### 1. Native runtime (WSL / Linux)

arm64 devices:

```bash
bash native/toolchain/build-node24.sh        # Node 24.22.1 (jitless), the slow one
bash native/build-bash.sh                    # Bash 5.3 (GPL-3.0)
bash native/iec/scripts/build_toybox.sh      # toybox
bash native/iec/scripts/build_libarchive.sh  # tar/cpio/unzip/zip
bash scripts/pack-native.sh                  # libs + engine archive → entry/
```

x86_64 emulator: see [docs/X86_64-BUILD.md](docs/X86_64-BUILD.md) and the `setup / node / tools /
bash / addons / rg / pack` phases of `scripts/build-x86-runtime.sh`.

The toolchain, official engine and source caches default to `/var/tmp/deepseek-harmony-native` on the
build host (override with `NATIVE_BASE`); `native/toolchain/README.md` explains the LLVM 22 +
libc++ 22 `__n1` setup.

### 2. HAP

```bash
# Only Node 18+ is required; a full DevEco installation is enough (no IDE session)
node scripts/build.mjs --deveco-home "<DevEco install dir>"
node scripts/build.mjs --clean   # after changing native libs
```

`build-profile.json5` is gitignored (it contains signing paths and passwords); only
`build-profile.example.json5` is committed. Signing is configured locally.

### 3. App pack (optional, only for a future store release)

This project is **not planned for AppGallery** for now, so this step is normally unnecessary. If you
do want a store package later, run `assembleApp` in project mode:

```bash
# Point at DevEco's SDK and JBR; alternatively use Build → Build App in DevEco
DEVECO_SDK_HOME="<DevEco>/sdk" JAVA_HOME="<DevEco>/jbr" \
  node "<DevEco>/tools/node/node.exe" "<DevEco>/tools/hvigor/bin/hvigorw.js" \
  --mode project -p product=default -p buildMode=release assembleApp --no-daemon
```

Output: `build/outputs/default/*.app`; the single HAP is at
`entry/build/default/outputs/default/entry-default-signed.hap`.

## Signing and distribution

- **On-device debugging** requires a debug profile for `com.snoworwind.phoh` that lists the
  device UDID (generate it in DevEco → Project Structure → Signing Configs).
- **GitHub Releases** ship an **unsigned** HAP and native libraries; sign them yourself before
  installing.
- This project is **not intended for Huawei AppGallery**; if you publish it yourself, you need a
  release certificate/profile and you are responsible for store review, filings, trademark and
  AI-service compliance.
- A **release-signed HAP cannot be installed with `hdc install`** (`9568322 not trusted app
  source`); do not use it for local testing.

## Tests

```bash
node scripts/test.cjs                  # 28 host-side tests (session protocol, SSE, path sandbox, JSON-RPC)
node scripts/test-fetch-polyfill.cjs   # 15 fetch-polyfill tests (JSON/SSE/redirect/FormData/abort)
bash scripts/audit-sources.sh          # unpack the HAP, verify binaries and npm.tar.gz
bash scripts/check-engine-web.sh       # web profile: 291 plugins, empty stderr
```

See [docs/VALIDATION.md](docs/VALIDATION.md) for what has been verified on device and what has not.

## Runtime layout

```text
filesDir/
  runtime-<version>/           bin/     command launchers (#IECSOv2)
                               engine/  official engine + harmony/ host scripts
                               certs/   cacert.pem + bundle.pem
                               home/ tmp/
  harness-home/                DSH_HOME (profiles, sessions, settings, credentials)
```

- The runtime directory name is derived from a content digest; changing the engine, npm or any
  native library triggers a fresh unpack, and stale `runtime-*` directories are removed after a
  successful start (~450 MB each).
- `harness-home` is never deleted by the app: upgrades keep sessions and settings.
- Corrupted runtimes are rebuilt automatically once, then the UI offers a "re-unpack" action.

## Runtime patches

Node runs with `--jitless` on HarmonyOS, so V8 does not expose WebAssembly and the built-in
`fetch` (undici) cannot parse HTTP. The runtime injects a pure-JS
`harmony/fetch-polyfill.cjs` via `NODE_OPTIONS=--require`:

- request bodies: string / Buffer / TypedArray / ArrayBuffer / URLSearchParams / Blob /
  FormData (multipart) / ReadableStream / Node Readable;
- responses: streaming bodies (SSE is not buffered), gzip/br/deflate;
- redirects follow/error/manual with method rewriting; `AbortSignal` rejects with
  `AbortError`; HEAD/204/304 have a null body; responses expose `url/type/redirected`.

V8 DrumBrake (the WASM interpreter) is not viable here: the DrumBrake sources bundled with Node
24.22.1 no longer compile against the same V8 (about 50 errors), and the interpreter still
allocates executable memory, which conflicts with HarmonyOS's no-JIT policy.
`scripts/patch-v8-drumbrake.sh` is kept only as a record of the investigation.

TLS trust comes from the runtime CA bundle: Mozilla roots plus an optional
`rawfile/harmony/extra-ca.pem`, merged into `certs/bundle.pem` at startup. `extra-ca.pem` is the
root CA of an HTTPS interception proxy used in some development environments and is **not shipped
in this repository**; provide it yourself if needed. Public/store builds should leave it absent
(Mozilla roots only) or replace it with your own enterprise root.

## Known limitations

- First launch unpacks a 43.8 MB engine archive (~25k files), about 1–2 minutes on a phone.
- Background keep-alive uses a location continuous task; it needs approximate-location permission
  and only affects background survival.
- `dsh web` binds `127.0.0.1` only; the UI is reachable only from the in-app Web component.
- The engine's process sandboxing (bwrap / Landlock) is generally unavailable on HarmonyOS;
  capability limits come from permission presets and tool switches.
- `fork` is not intercepted; the terminal PTY relies on `forkpty` compatibility.
- Not included: Python, MCP, voice, plugin marketplace, persistent background execution.

## Licensing

- Original code: MIT, see [LICENSE](LICENSE).
- Upstream DeepSeek Harness: MIT; copyright and permission notices are kept in the shipped archive.
- Third-party components, license texts and the corresponding source for GNU Bash:
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- License texts live in `LICENSES/` and are shipped inside the HAP, extracted to `files/notices/`.
- Component provenance and build recipes: [docs/SOURCES.md](docs/SOURCES.md).
