# dsh-desktop-linux

**官方 DeepSeek Harness 桌面版（Electron 外壳）的 Linux (x64) 非官方移植。**

上游 [`deepseek-ai/deepseek-harness`](https://github.com/deepseek-ai/deepseek-harness)
的桌面版在 `apps/desktop`，但发布矩阵只允许
`mac-arm64 | mac-x64 | win-x64`：

```
Linux is not a supported Desktop release target
```

不过 Linux 的代码路径其实都在。本仓库是让它能在 Linux 上跑起来的**最小补丁集 + 构建套件 +
安装器**——不是重写，也不是重新打包 AppImage。产物由上游**自己的**打包流水线
`pnpm run package:desktop:dir` 生成，退出码 `0`，且通过上游的两道 smoke 门禁。

验证基线：tag **`dsh-v0.2.0-rc.2`**（commit `639ed015`），2026-09-30。

> English: [README.md](README.md)

---

## 产物验证

- `pnpm run package:desktop:dir` → `EXIT=0`
- payload smoke → `{"node":"24.18.1","platform":"linux","arch":"x64","koffi":true,"sharp":true,"html":true,"pty":true,"pnpm":true,"grep":true,"glob":true}`
- packaged smoke → `desktop runtime: DOCX, XLSX, PPTX to PDF and skill CLI discovery passed`
- Electron `44.0.0`
- `scripts/verify-payload.sh` → `PASS`（有 `@img/sharp-wasm32` + `@emnapi/runtime`，无 `@img/sharp-linux-x64`）

载荷目录：`apps/desktop/.desktop-build/targets/linux-x64/artifacts/linux-unpacked`
（约 1.1 GB，单个 `deepseek-harness` 二进制）。

## 快速开始

```sh
git clone https://github.com/mtongle/dsh-desktop-linux
cd dsh-desktop-linux

./scripts/bootstrap.sh                  # 浅克隆上游 @ dsh-v0.2.0-rc.2、打补丁、vendor、写 .env.linux
./scripts/build.sh                      # pnpm install + build + package:desktop:dir（冷构建约 15 分钟）

DSH_DESKTOP_PAYLOAD=~/build/deepseek-harness/apps/desktop/.desktop-build/targets/linux-x64/artifacts/linux-unpacked \
  bash install/install.sh               # 装到 ~/.local，不需要 sudo
```

然后运行 `deepseek-harness-desktop`，或在应用菜单里找 **DeepSeek Harness**。

Harness 数据在 `~/.dsh`（profile `desktop`），与 `dsh` CLI 共享。安装脚本**完全不碰它**，
并且会把旧安装备份成 `~/.local/opt/deepseek-harness-desktop.bak-<时间戳>`。

### 预编译产物（不想自己构建）

[Releases](../../releases) 里挂着压缩后的产物，**作为独立资产**
（`deepseek-harness-desktop-linux-x64-<时间戳>.tar.zst`，约 355 MB，附 `.sha256`）。
只由手动触发 [`build-linux-desktop`](.github/workflows/build-linux-desktop.yml) 工作流产出，
构建过程就是上面的流水线，并且以 `verify-payload.sh` 为门禁。

```sh
tar -I zstd -xf deepseek-harness-desktop-linux-x64-*.tar.zst
DSH_DESKTOP_PAYLOAD="$PWD/linux-unpacked" bash install/install.sh
```

`.tar.zst` 里只有解包后的应用目录——没有安装器，没有 Arch 专属打包。
不在本仓库假设的 `~/.local` 布局上的话，自己写个 `install.sh` 即可。

### 依赖

- Arch Linux（其实任何 glibc 发行版都行，这里没有 Arch 专属的东西）
- Node.js `>= 24`、`pnpm@11.7.0`
  （Arch 的 `nodejs` 没有 corepack：`npm i -g --prefix ~/.local/share/pnpm-self pnpm@11.7.0`）
- 构建树约需 10 GB 空闲磁盘

## 三处修复

少任何一处，要么流水线挂，要么应用崩。三处都是只会在 Linux 上现形的上游真 bug。
定位过程见 [docs/pitfalls.md](docs/pitfalls.md)（中文，13 条）。

### 1. Linux 发布目标（17 文件，`patches/0001-desktop-linux-port.patch`）

放宽 target 白名单和平台联合类型；把运行时准备指向 Linux 的扁平 `electron` 布局，
而不是 macOS 的 `Electron.app/Contents/…`；给自动更新和上传计划加上 `linux-x64`；
指定可执行文件名；并且在 Linux 上**不烤任何强制更新策略**
（`main.ts` 把它限制在 win32/darwin——manifest 里带了策略，应用会在启动阶段
以 `desktop policy: unsupported platform` 直接死）。

同时提供 `apps/desktop/.env.linux`（上游没有这个模板，本仓库放的是 `config/env.linux`）。

### 2. sharp 改用 WebAssembly

sharp 的原生二进制在 Linux + Electron 下**段错误**
（[electron#46323](https://github.com/electron/electron/issues/46323)：Electron 的 glib 符号
泄漏进 sharp 自带的 libvips，第一次真正的图片操作就把进程带走）。开发过程中应用这样死了两次，
留下 40 MB core dump。

- `runtime-file-policy.ts` —— Linux 目标排除 `@img/sharp-linux-x64`。这样 sharp 的运行时
  平台 `require` 会抛错，控制流落到 `dist/sharp.mjs` 末尾的 `@img/sharp-wasm32` 兜底分支。
  （**光设环境变量没用**：`npm_config_arch` 只影响 `buildPlatformArch()`，
  永远影响不到 `runtimePlatformArch()`。）
- `prepare-dsh.ts` —— 新增 `runtime:materialize-linux-shims` 步骤，把 vendor 的 wasm 包
  拷进准备树的 `node_modules`。
- `vendor/sharp-wasm32/` —— `@img/sharp-wasm32@0.35.5`、`@emnapi/runtime@1.11.3`、
  `tslib@2.8.1`。二进制不入补丁，由 `scripts/fetch-sharp-wasm-vendor.sh` 抓。
- `smoke-prepared-runtime.ts` —— smoke 前 `delete environment.NODE_PATH`。这才是让 smoke
  **段错误**（而不只是警告）的真凶：`tsx` 把 `NODE_PATH` 设成仓库自己的
  `node_modules/.pnpm/…`，`smokePreparedRuntime` 把 `process.env` 展开进子进程，
  这些目录进了 `Module.globalPaths`，于是
  `require('@img/sharp-linux-x64/sharp.node')` 解析到**构建机上的原生 sharp 0.35.3**，
  而不是准备树里的 wasm 版本。手动跑同一个 smoke 会通过——典型的海森堡 bug。

### 3. LibreOffice 引擎探测

`@deepseek-ai/libreoffice-kit` 只为 macOS/Windows 发布原生引擎；Linux 上
`selectOfficeEngine()` 正确地返回 `wasm`。但在打包后的应用里这条兜底路径**不可达**，
因为 **Electron 的 asar shim 让 `fs.lstatSync()` 对 `app.asar` 内任意路径都返回 stat**
——包括荒唐得不可能存在的路径。于是 `installedPackageExists()` 声称从未发布过的
`@deepseek-ai/libreoffice-kit-linux-x64-glibc` 存在，`resolveEngine()` 抛
`Installed LibreOfficeKit package is incomplete`，而不是用 wasm。
`prepare-dsh.ts` 把这个探测改写成用模块解析器，它在 asar 里说的是实话。
之后 DOCX/XLSX/PPTX → PDF 就能走 wasm 正常工作了。

## 目录

```
patches/0001-desktop-linux-port.patch   17 文件的 Linux 移植（对 639ed015 干净应用）
scripts/bootstrap.sh                    浅克隆 + 打补丁 + vendor + .env.linux
scripts/build.sh                        上游自己的打包流水线
scripts/verify-payload.sh               校验产物确实带上了 Linux 修复
scripts/fetch-sharp-wasm-vendor.sh      vendor wasm sharp 包
config/env.linux                        apps/desktop/.env.linux 模板
install/install.sh                      ~/.local 安装器（免 sudo）
install/deepseek-harness-desktop        启动器（带 GPU 失败兜底）
install/deepseek-harness.desktop.in     桌面项模板
docs/pitfalls.md                        13 条坑 + 定位方法（中文）
.github/workflows/build-linux-desktop.yml   构建门禁 + 发布
```

## 启动器行为

Electron 在 Wayland/XWayland 下的 GPU 初始化有竞态，可能这样挂掉：

```
GPU process launch failed: error_code=1002
FATAL:gpu_data_manager_impl_private.cc:417] GPU process isn't usable. Goodbye.
```

启动器先走正常路径，**只在捕获的日志里出现这个确切特征**时才用 `--disable-gpu` 重试一次，
所以正常退出永远不会被重试，无关的失败也保留原本的退出码。
`DSH_DESKTOP_FORCE_DISABLE_GPU=1` 可强制软件渲染。

## 状态与注意事项

- **只验证了一个版本、一个架构。** 仅对 `dsh-v0.2.0-rc.2` / `linux-x64` 验证过。上游会随意
  重构 `apps/desktop/scripts/`，换 commit 后 `git apply` 会拒绝——这正是预期的失败方式。
- **CI 是门禁，不是定时任务。** 改动 `patches/`、`scripts/`、`config/`、`install/` 的 push 会跑完整
  构建 + `verify-payload.sh`（约 20 分钟，不产 artifact）。**发布只由手动 `workflow_dispatch` 触发**，
  不会背着你发东西。一次完整构建约 15 分钟，产物 1.1 GB（压缩后 355 MB）。
- **不是 DeepSeek 官方支持。** 上游是**刻意**把 Linux 排除在桌面发布矩阵外的；
  对 `download.deepseek.com/dsh-desk/feeds/linux-x64/` 的自动更新请当作不确定。
- 桌面外壳本身是官方的，本仓库不添加任何产品代码。

## 许可

MIT。`patches/` 是 `deepseek-harness`（MIT，© 2026 DeepSeek）的衍生作品。
