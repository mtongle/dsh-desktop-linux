# dsh-desktop-linux

**Unofficial Linux (x64) port of the official DeepSeek Harness Desktop shell.**

Upstream [`deepseek-ai/deepseek-harness`](https://github.com/deepseek-ai/deepseek-harness)
ships a desktop app as an Electron shell in `apps/desktop`, but its release machinery
allowlists only `mac-arm64 | mac-x64 | win-x64`:

```
Linux is not a supported Desktop release target
```

The Linux code paths are already there, though. This repo is the **minimal patch set,
build kit and installer** that makes upstream's *own* packaging pipeline complete on
Linux — not a reimplementation, not a repackaged AppImage. The result is built by
`pnpm run package:desktop:dir`, exits `0`, and passes both of upstream's smoke gates.

Verified against tag **`dsh-v0.2.0-rc.2`** (commit `639ed015`), 2026-09-30.

> 中文说明见 [README.zh-CN.md](README.zh-CN.md)。

---

## What it produces

| Check | Result |
| --- | --- |
| `pnpm run package:desktop:dir` | `EXIT=0` |
| payload smoke | `{"node":"24.18.1","platform":"linux","arch":"x64","koffi":true,"sharp":true,"html":true,"pty":true,"pnpm":true,"grep":true,"glob":true}` |
| packaged smoke | `desktop runtime: DOCX, XLSX, PPTX to PDF and skill CLI discovery passed` |
| Electron | `44.0.0` |
| `scripts/verify-payload.sh` | `PASS` — `@img/sharp-wasm32` + `@emnapi/runtime` present, `@img/sharp-linux-x64` absent |

Payload: `apps/desktop/.desktop-build/targets/linux-x64/artifacts/linux-unpacked`
(~1.1 GB, single `deepseek-harness` binary).

## Quick start

```sh
git clone https://github.com/mtongle/dsh-desktop-linux
cd dsh-desktop-linux

./scripts/bootstrap.sh                  # shallow-clone upstream @ dsh-v0.2.0-rc.2, apply patch, vendor, .env.linux
./scripts/build.sh                      # pnpm install + build + package:desktop:dir  (~15 min cold)

DSH_DESKTOP_PAYLOAD=~/build/deepseek-harness/apps/desktop/.desktop-build/targets/linux-x64/artifacts/linux-unpacked \
  bash install/install.sh               # install into ~/.local, no sudo
```

Then launch `deepseek-harness-desktop`, or pick **DeepSeek Harness** from your app menu.

Harness state lives in `~/.dsh` (`profiles/desktop`), shared with the `dsh` CLI.
The installer never touches it, and backs up any previous install to
`~/.local/opt/deepseek-harness-desktop.bak-<timestamp>`.

### Prebuilt payload (no local build)

[Releases](../../releases) carry the compressed payload as a standalone asset
(`deepseek-harness-desktop-linux-x64-<stamp>.tar.zst`, ~355 MB, plus a `.sha256`).
It is only produced by a manual run of the [`build-linux-desktop`](.github/workflows/build-linux-desktop.yml)
workflow, which builds with the pipeline above and gates on `verify-payload.sh`.

```sh
tar -I zstd -xf deepseek-harness-desktop-linux-x64-*.tar.zst
DSH_DESKTOP_PAYLOAD="$PWD/linux-unpacked" bash install/install.sh
```

The `.tar.zst` contains nothing but the unpacked application directory — no installer,
no Arch-specific packaging. Bring your own `install.sh` if you are not on the `~/.local`
layout this repo assumes.

### Requirements

- Arch Linux (or any glibc distro — nothing here is Arch-specific)
- Node.js `>= 24`, `pnpm@11.7.0`
  (Arch's `nodejs` has no corepack: `npm i -g --prefix ~/.local/share/pnpm-self pnpm@11.7.0`)
- ~10 GB free disk for the build tree

## The three fixes

Without all three the pipeline fails or the app crashes. Each one is a real upstream
bug that only manifests on Linux; details and diagnosis notes in
[docs/pitfalls.md](docs/pitfalls.md).

### 1. Linux release target (17 files, `patches/0001-desktop-linux-port.patch`)

Widens the target allowlists and platform unions, points the runtime preparation at
Linux's flat `electron` layout instead of macOS's `Electron.app/Contents/…`, adds
`linux-x64` to the auto-update and upload plans, names the executable, and bakes **no
mandatory-update policy** on Linux (`main.ts` gates it to win32/darwin — a policy in
the manifest makes the app die at startup with `desktop policy: unsupported platform`).

Also ships `apps/desktop/.env.linux`, which upstream has no template for
(`config/env.linux` here).

### 2. sharp → WebAssembly

sharp's native binding **segfaults under Electron on Linux**
([electron#46323](https://github.com/electron/electron/issues/46323)): Electron's glib
symbols leak into sharp's bundled libvips, and the first real image operation takes the
process down. The app died this way twice during development, leaving 40 MB core dumps.

- `runtime-file-policy.ts` — for Linux targets, exclude `@img/sharp-linux-x64`. That
  makes sharp's runtime-platform `require` throw so control falls through to its
  `@img/sharp-wasm32` fallback at the end of `dist/sharp.mjs`.
  (An env var alone does **not** work: `npm_config_arch` only affects
  `buildPlatformArch()`, never `runtimePlatformArch()`.)
- `prepare-dsh.ts` — new `runtime:materialize-linux-shims` step copies the vendored
  wasm packages into the prepared tree's `node_modules`.
- `vendor/sharp-wasm32/` — `@img/sharp-wasm32@0.35.5`, `@emnapi/runtime@1.11.3`,
  `tslib@2.8.1`. Not in the patch (binaries); fetched by
  `scripts/fetch-sharp-wasm-vendor.sh`.
- `smoke-prepared-runtime.ts` — `delete environment.NODE_PATH` before the smoke. This
  is what actually made the smoke *segfault* rather than merely warn: `tsx` sets
  `NODE_PATH` to the repo's own `node_modules/.pnpm/…`, `smokePreparedRuntime` spread
  `process.env` into the child, those dirs entered `Module.globalPaths`, and
  `require('@img/sharp-linux-x64/sharp.node')` resolved the **build host's native
  sharp 0.35.3** instead of the prepared tree's wasm one. Running the smoke by hand
  passes — a heisenbug until you print `require.resolve` under the pipeline's env.

### 3. LibreOffice engine probe

`@deepseek-ai/libreoffice-kit` publishes native engines only for macOS/Windows; on
Linux `selectOfficeEngine()` correctly returns `wasm`. That fallback was unreachable in
a packaged app because **Electron's asar shim makes `fs.lstatSync()` report a stat for
any path inside `app.asar`** — including absurd ones. So `installedPackageExists()`
claimed the never-published `@deepseek-ai/libreoffice-kit-linux-x64-glibc` was present
and `resolveEngine()` threw `Installed LibreOfficeKit package is incomplete` instead of
using wasm. `prepare-dsh.ts` rewrites the probe to use the module resolver, which tells
the truth inside an asar. DOCX/XLSX/PPTX → PDF then works via wasm.

## Layout

```
patches/0001-desktop-linux-port.patch   the 17-file Linux port (applies to 639ed015)
scripts/bootstrap.sh                    clone + patch + vendor + .env.linux
scripts/build.sh                        upstream's own packaging pipeline
scripts/verify-payload.sh               assert the payload carries the Linux fixes
scripts/fetch-sharp-wasm-vendor.sh      vendor the wasm sharp packages
config/env.linux                        apps/desktop/.env.linux template
install/install.sh                      ~/.local installer (no sudo)
install/deepseek-harness-desktop        launcher (GPU-failure fallback)
install/deepseek-harness.desktop.in     desktop entry template
docs/pitfalls.md                        the 13 traps, with diagnosis notes
.github/workflows/build-linux-desktop.yml   build gate + release publisher
```

## Launcher behaviour

Electron's GPU bring-up is racy under Wayland/XWayland. A launch can abort with:

```
GPU process launch failed: error_code=1002
FATAL:gpu_data_manager_impl_private.cc:417] GPU process isn't usable. Goodbye.
```

The launcher takes the normal path first and falls back to `--disable-gpu` **only when
that exact signature appears** in the captured log, so a normal quit is never retried
and unrelated failures keep their exit code. `DSH_DESKTOP_FORCE_DISABLE_GPU=1` forces
software rendering.

## Status & caveats

- **One release, one architecture.** Verified only against `dsh-v0.2.0-rc.2` /
  `linux-x64`. Upstream refactors `apps/desktop/scripts/` freely; `git apply` will
  reject the patch on other commits, which is the intended failure mode.
- **CI is a gate, not a nightly.** Pushes touching `patches/`, `scripts/`, `config/` or
  `install/` run the full build plus `verify-payload.sh` (~20 min, no artifact). Releases
  are only cut by a manual `workflow_dispatch`, so nothing is published behind your back.
  A full rebuild needs ~15 min and produces a 1.1 GB payload (355 MB compressed).
- **Not endorsed by DeepSeek.** Upstream deliberately excludes Linux from the desktop
  release matrix; treat auto-update against `download.deepseek.com/dsh-desk/feeds/linux-x64/`
  as speculative.
- The desktop shell is the official one — this repo adds no product code.

## License

MIT. `patches/` is a derivative work of `deepseek-harness` (MIT, © 2026 DeepSeek).
