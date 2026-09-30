# 踩坑记录（13 条）

每一条都是实测撞出来的，附带定位方法。按"会不会让你卡住"排序，不按发现顺序。

---

## 1. `NODE_PATH` 污染会让 payload smoke 段错误

**症状**：`smoke-prepared-runtime` 失败，日志里是 `SharpElectronLinux` 警告 + SIGSEGV，
**但准备好的运行时其实是正确的**。

**原因**：`tsx` 会把 `NODE_PATH` 设成仓库自己的 `node_modules/.pnpm/...`。
`smokePreparedRuntime` 把 `process.env` 原样展开进子进程，于是这些目录进了
`Module.globalPaths`，`require('@img/sharp-linux-x64/sharp.node')` 解析到**构建机上的原生
sharp 0.35.3**，而不是准备树里的 wasm 版本 → 段错误。

**定位**：写个脚本，在流水线的环境（`desktopNodeEnvironment`）下打印
`require.resolve('@img/sharp-linux-x64/sharp.node')` 和
`Module._nodeModulePaths(<tree>/node_modules/sharp/dist)`。

**修复**：`smoke-prepared-runtime.ts` 里 `delete environment.NODE_PATH`。

**为什么像玄学 bug**：只有父进程是 `tsx` 时才发作。手动跑同一个 smoke 永远通过。

---

## 2. Electron 的 asar `lstatSync` 会说谎

Electron 对 `app.asar` 内**任意**路径都返回 stat，哪怕那个路径荒唐得不可能存在。
所以任何写成 `fs.lstatSync(p, { throwIfNoEntry: false })` 的"这个包装了吗"检查
在打包后的应用里**恒为 true**。

**受害者**：`@deepseek-ai/libreoffice-kit` 的 `installedPackageExists()` →
`resolveEngine()` 抛 `Installed LibreOfficeKit package is incomplete`，
wasm 兜底分支永远不可达 → Linux 上 docx/xlsx/pptx 转 PDF 根本不可能。

**修复**：改用模块解析器探测：

```js
try { require.resolve(name + "/package.json"); return true } catch { return false }
```

模式匹配不上时要**显式报错**，别静默跳过。

macOS/Windows 上原生引擎真实存在，所以上游一直没发现。

---

## 3. `desktop policy: unsupported platform` — 打包好的应用一启动就死

`main.ts` 把 `dshMandatoryUpdatePolicy` 限制在 win32/darwin。Linux 上如果 manifest 里
**烤进了**策略，应用会在启动阶段直接退出。

**修复**：`electron-builder-config.mjs` 里 Linux 不烤策略
（`resolvedPlatform === 'linux' ? undefined : …`）。

顺带：`validateDesktopPackageEnvironment` 会无条件调用
`resolveDesktopPolicyEnvironment`，要求 `DSH_DESKTOP_MANDATORY_UPDATE_{TEST,PROD}_ORIGIN`，
即使 Linux 根本不烤策略。给它加个 Linux 跳过，否则你得凭空编一个 origin 出来。

---

## 4. 陈旧的 writer lock 会让 Host 起不来

`~/.dsh/.credentials.yaml.lock`（0 字节、mtime 很旧）会让 Host 死于：

```
atomic-write: timed out waiting for the writer lock
```

确认没有 dsh 进程持锁后直接删。

---

## 5. `prepare:dsh` 单独跑不会加载 `.env.linux`

`.env.linux` 是 `package-target.ts` 读的，不是 `prepare-dsh.ts` 读的。所以直接
`pnpm --filter @deepseek-ai/dsh-desktop run prepare:dsh` 会退回
`registry.npmjs.org`，以 ~40 KiB/s 爬行。

单独迭代 `prepare:dsh` 时自己 export `DSH_DESKTOP_NPM_REGISTRY`。

---

## 6. 代理：7891 慢 4 倍，npmmirror 直连更快

实测（本机）：

- `socks5h://127.0.0.1:7893` → **4.43 MB/s**
- 直连 → 3.22 MB/s
- `http://127.0.0.1:7891` → 1.14 MB/s

而且 **npmmirror 直连比走 7891 快 3 倍**。所以：

- 给 pnpm/npm **完全不挂代理**（npmmirror 是国内的）
- GitHub / curl 才走 `-x socks5h://…`

另外：**Node 的 `fetch` 默认忽略 `HTTP(S)_PROXY`**，除非 `NODE_USE_ENV_PROXY=1`（Node 24+）。
主运行时下载器（`scripts/primary-runtime/prepare.ts`）用的是全局 fetch，
不设这个标志就死在 `fetch failed`。

---

## 7. electron 的 postinstall 不会跑

workspace 安装下 electron 的 postinstall 被跳过，二进制得手动取：

```sh
(cd node_modules/.pnpm/electron@*/node_modules/electron && node install.js)
# 验证
node_modules/.pnpm/electron@*/node_modules/electron/dist/electron --version  # v44.0.0
```

它复用 `~/.cache/electron`，重复构建不重新下载。

---

## 8. `curl` 抓 npm 包必须带 `-L`

registry 会 302 到 CDN。忘了 `-L` 你会得到一个 101 字节的
"Redirecting to …" 文件，然后 `tar` 报错或者更糟——静默装进去一个垃圾包。

抓完先 `tar tzf` 验一遍。

---

## 9. `pkill -f "<pattern>"` 会杀掉自己

从 agent shell 里跑 `pkill -f` 会匹配到包装它的那个 shell 本身，命令直接 `-15` 结束。
匹配更窄的字符串，或者用会话 id 走进程管理。

---

## 10. 启动需要会话环境变量

```
DISPLAY=:1 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000
ELECTRON_OZONE_PLATFORM_HINT=auto
```

Electron 在 Wayland 下会选 XWayland，在 niri 上工作正常。

---

## 11. 首次启动有 GPU 竞态

可能连续 6 次 `GPU process launch failed: error_code=1002`，然后
`FATAL:...gpu_data_manager_impl_private.cc:417] GPU process isn't usable. Goodbye.`

非确定性，重试一次通常就好。验证方式：确认存在 `--type=gpu-process` 子进程，
**并且** `ss -ltnp | grep 19387` 能看到 Host 在监听。

启动器已经带了这个兜底（只在日志出现该特征时用 `--disable-gpu` 重试一次）。

---

## 12. `deepseek-harness --version` 不会打印版本

它会**启动 GUI**。别拿它当探针，会挂住直到你手动杀。

---

## 13. 删构建树别指望 `pnpm store prune` 回收空间

树的 `node_modules` 是指向 store（以及其他活跃 pnpm 项目）的**硬链接**，
所以 `du -sh` 会高估 `rm -rf` 真正释放的空间。

---

## 附：userData 与崩溃日志

Electron 用的是包名而不是 productName：

```
~/.config/@deepseek-ai/dsh-desktop/
```

崩溃报告在 `logs/crash-*-host.log`——先看这里。Host 崩溃的典型形态：

```
Error: dsh desktop host stopped: … [SharpElectronLinux] Warning: …
```
