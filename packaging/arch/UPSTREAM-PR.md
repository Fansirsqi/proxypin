# 上游 PR + AUR 发布指南

> 结论：**两者都可行**，但建议顺序是：先提 PR（把修复变成上游代码）→ 再发 AUR
> `proxypin-git`。AUR 的 release 包（`proxypin`）等上游发新版本再更新。

## 一、现状（2026-11 查询）

| AUR 包 | 版本 | 维护者 | 说明 |
| --- | --- | --- | --- |
| `proxypin` | 1.2.9-2 | **null（孤儿包）** | 源码构建包，已废弃状态，可申请收养 |
| `proxypin-bin` | 1.3.3-1 | zxp19821005 | 重打包 deb，URL 还指向旧仓库名 |
| `proxypin-bin-fixed` | 1.2.7-1 | Fansirsqi（= 你？） | “KDE6 兼容 + 运行时修复” |

上游仓库活跃（14.3k star，最近 65 个关闭 PR 里 29 个被合并），**接受外部 PR**。

已提交（2026-11-10 首提，2026-11-17 更新正文并关闭 #999）：

| PR | 分支 | 内容 | 状态 |
| --- | --- | --- | --- |
| #996 | `fix/linux-build` | 编译期：appindicator 弃用告警、`dart_api_dl`、图标路径 | open，clean |
| #997 | `fix/linux-runtime` | 运行期：CA 安装（polkit）、托盘/关闭/退出、Plasma 6 系统代理 + 配置快照还原 | open，clean |
| #999 | `fix/linux-windows` | Linux 子窗口改内嵌路由、quickjs 桥接库、JS 输出面板、无边框窗口边缘缩放 | **closed**，内容已随 #1000 提交 |
| #1000 | `feat/ui-settings-and-fonts` | 抓包列表密度、代码字体/字号、界面字体/字号、界面密度；含 #999 的四个提交，共 51 文件 | open，clean |

建议合并顺序：#996 → #997 → #1000（都基于 `main`，前者合入后 diff 会自动收敛）。

#999 关闭原因：它的四个提交正是 #1000 分支的前四个提交（`git diff --name-only` 对比，`fix/linux-windows` 没有 #1000 之外的文件），单独编译又缺 #1000 引入的 `code_style.dart`，所以只保留 #1000。

## 二、往上游提 PR

### 原则

- **拆成两个 PR**，一个编译期、一个运行期，reviewer 好审：
  1. `fix(linux): build with current Arch toolchains`
     - `linux/CMakeLists.txt`：`-Wno-error=deprecated-declarations`、`dart_api_dl.c` + `--export-dynamic`
     - `linux/my_application.cc`：窗口图标不再写死 `/opt/proxypin`
  2. `fix(linux): install system CA via polkit, make close/quit work`
     - `lib/ui/desktop/ssl/cert_installer.dart`、`lib/ui/desktop/ssl/pc_cert.dart`
     - `lib/utils/desktop_tray.dart`、`lib/ui/launch/launch.dart`
- **不要带上**：`pubspec.lock`（我们是本地重解析的）、`analysis_options.yaml`（flutter 工具自动改的）、`packaging/`（Arch 打包属于 AUR，不进应用仓库）。
- 新文案如果 upstream 要求走 l10n：`pc_cert.dart` 里我沿用了该文件原有的 `isCN ? ... : ...` 内联写法；若被要求，改成 `lib/l10n/app_en.arb` + `app_zh.arb` 的 key。
- `flutter analyze` 只报改动前就存在的 3 个 info（`menu_base` 直接 import 相关）；`flutter test` 的 5 个失败在纯 HEAD 上同样失败（依赖被重解析导致），PR 里说明“pre-existing, unrelated”。

### 别人怎么提的（2026-11 观察上游已合并 PR）

| PR | 语言 | 长度 | 结构 |
| --- | --- | --- | --- |
| #966 SSE 响应体 | 英文 | ~30 行 | Summary / What changed / Test |
| #942 VPN 端口 | 中文 | ~15 行 | 问题 / 根因 / 修复 |
| #921 h2c | 英文 | ~50 行 | Problem / Changes / Validation |
| #865 VPN 切网 | 英文 | ~40 行 | Problem / Root cause / Fix / Files / Testing |

共同点：单语、开头一句话说清“什么坏了”，改动按文件/子系统列 bullet，验证只写可复现的结论；
不贴大段日志，除了“Generated with …”这类声明，正文没有多余的元信息。

上游没有双语 PR 的先例，但维护者是中文母语、仓库面向国际用户，所以本仓库统一用
**英文正文 + `## 中文` 摘要**：每段 6–10 行，长表格只留一张最有说服力的（改前/改后对照）。

### PR 正文（双语，2026-11-17 更新，已同步到 GitHub）

#996 `fix/linux-build`：

```markdown
## Problem

Linux builds break, or ship a degraded app, with current toolchains:

- `tray_manager` still calls the deprecated `app_indicator_*` API and is compiled with `-Werror`, so clang 19 / gcc 15 abort the build with libayatana-appindicator 0.6.
- `libcode_forge.so` fails with `undefined symbol: Dart_CurrentIsolate_DL`: current engines no longer export `Dart_*`, so `RustLib.init()` fails and the editor features degrade.
- The window icon is hardcoded to `/opt/proxypin/...`, so any other install prefix gets a GTK warning and no icon.

## Changes

- `linux/CMakeLists.txt`: deprecation warnings are not errors; compile the SDK's `dart_api_dl.c` into the runner and export the dynamic symbol table.
- `linux/my_application.cc`: resolve the icon relative to `/proc/self/exe`.

## Testing

`flutter build linux --release` on Arch/CachyOS (Flutter 3.47.9, clang 23): 45 `Dart_*` symbols exported, no `RustLib.init failed`; installed under `/usr/lib/proxypin`, the icon loads without warnings.

## 中文

当前工具链下 Linux 构建会失败或功能降级：appindicator 弃用 API 被 `-Werror` 拦下；引擎不再导出 `Dart_*`，`libcode_forge.so` 报 `undefined symbol`，编辑器功能静默失效；窗口图标写死 `/opt/proxypin`。

改动：CMake 不再把弃用告警当错误，编入 SDK 的 `dart_api_dl.c` 并导出符号；图标按 `/proc/self/exe` 解析。已在 Arch/CachyOS 上构建并安装验证（图标正常、无 `RustLib.init failed`）。
```

#997 `fix/linux-runtime`：

```markdown
## Problem

Three Linux runtime issues (KDE Plasma 6, Wayland):

1. **Install certificate** fails silently: it writes `/usr/local/share/ca-certificates` and runs `update-ca-certificates` as a normal user (root is required, and Arch/Fedora use p11-kit or `update-ca-trust`).
2. **Close and quit do nothing**, the process lives on until `pkill`: `tray_manager` has no Linux `setToolTip` (throws `MissingPluginException`), and the fallback awaits `windowManager.destroy()`, which never returns.
3. **Stop** reports a failure while the listener keeps running, and wipes the user's proxy configuration: `proxy_manager` calls the removed `kwriteconfig5`, and `cleanSystemProxy()` sets `mode=none`, dropping PAC and manual settings.

## Changes

- `cert_installer.dart` / `pc_cert.dart`: pick the trust store per distribution, install and refresh in one `pkexec sh -c …` (a single polkit prompt), and add the CA to the NSS DB for Chrome/Chromium.
- `desktop_tray.dart` / `launch.dart`: create the tray at startup, tolerate the missing tooltip, verify that `hide()` actually hid the window, and exit without awaiting window destruction.
- `system_proxy.dart` / `server.dart`: use `kwriteconfig6` (fallback `kwriteconfig5`), snapshot the previous gsettings/KIO values and restore them on stop, and treat system-proxy failures as non-fatal.

## Testing

| Action | Before | After |
| --- | --- | --- |
| Install certificate | silent failure | polkit prompt, anchor + NSS DB written |
| Tray icon after launch | none | present at startup |
| Close → tray | exception, leftover process | window hidden, restorable |
| Close → quit | process alive | exits within a second |
| Stop | failure toast, port still open | port closed |
| System proxy after stop | `mode=none`, PAC lost | PAC URL / ports / kioslaverc restored |

No new `flutter analyze` issues; the 5 failing `flutter test`s fail on unpatched `main` as well.

## 中文

Plasma 6 / Wayland 下三处运行时问题：①装证书静默失败（普通用户写系统目录，Arch/Fedora 走 p11-kit）；②关窗/退出无反应，进程残留（`tray_manager` 没有 Linux tooltip 会抛异常，回退分支 `await destroy()` 永不返回）；③点停止报错但监听仍在，还会清空系统代理（Plasma 6 已移除 `kwriteconfig5`，`cleanSystemProxy()` 直接设 `mode=none`）。

改动：按发行版选信任库并合并为一次 `pkexec` 提权，同时写入 Chrome 的 NSS 库；启动即注册托盘、容错 tooltip、校验 `hide()`、退出不等待 destroy；改用 `kwriteconfig6`，停机前快照并在停机后还原 gsettings/KIO 配置，系统代理失败降级为非致命。
```

#1000 `feat/ui-settings-and-fonts`：

```markdown
## Summary

Four display settings, persisted in `ui_config.json` and exposed on both desktop and mobile preferences:

| Setting | Values |
| --- | --- |
| Capture list density | comfortable (default) / compact / dense — row padding, font sizes, meta line, icon sizes |
| Code font family + size | system default / any monospace family, 10–20 |
| Interface font family + scale | system default / any installed family, 85%–125% |
| Interface density | comfortable / compact / dense (`ThemeData.visualDensity`) |

`comfortable` reproduces the current layout exactly (row height 53px → 36px → 19px on a 1000px window). A shared `codeTextStyle()` keeps the body viewers, the CodeForge editors and the toolbox surfaces in sync; font families come from `fc-list` on Linux with a curated fallback list elsewhere.

This branch also carries the four Linux window/quickjs commits from #999 (now closed), so the diff is 51 files — the settings work is the last commit only.

## Testing

Plasma 6 with real captured traffic: rows measure 53/36/19px for the three densities, a custom code font renders in the body viewer, and interface font/scale apply to the UI while the code editors keep their own setting. `flutter analyze` is clean apart from pre-existing infos; `flutter test` unchanged.

## 中文

新增四个显示设置（抓包列表密度、代码字体与字号、界面字体与缩放、界面密度），存在 `ui_config.json`，桌面端和移动端的设置页都能修改。`comfortable` 与现状完全一致；共用 `codeTextStyle()` 让正文查看器、CodeForge 各编辑器和工具箱同步生效；Linux 用 `fc-list` 枚举字体，其它平台用内置列表。

本分支同时包含原 #999 的四个 Linux 子窗口/quickjs 提交（#999 已关闭），所以 diff 是 51 个文件，设置本身只是最后一个提交。
```

#999 关闭留言（已发）：

```markdown
Closing in favour of #1000: the four commits here are the first four commits of #1000's branch, so this content lands with #1000.

关闭本 PR，内容已完整包含在 #1000 中（这四个提交正是 #1000 分支的前四个提交）。
```

### 补丁清单（`packaging/arch/pr/`）

PR 1 —— 编译期，1 个 commit：

| 文件 | 内容 |
| --- | --- |
| `0001-fix-linux-build-with-current-toolchains-appindicator.patch` | appindicator 弃用告警不再 `-Werror`、`dart_api_dl.c` + `--export-dynamic`、图标路径按 `/proc/self/exe` 解析 |

PR 2 —— 运行期，3 个 commit（彼此独立，可整支 PR 一起提）：

| 文件 | 内容 |
| --- | --- |
| `0001-fix-linux-install-the-root-CA-through-polkit-with-di.patch` | pkexec 提权装 CA、按发行版选 trust store、写 Chrome NSS 库 |
| `0002-fix-linux-make-window-close-quit-and-the-tray-icon-w.patch` | 托盘启动即注册、tooltip 容错、hide 校验、退出不再 `await destroy` |
| `0003-fix-linux-handle-the-system-proxy-on-Plasma-6-and-re.patch` | `kwriteconfig6` 兼容、系统代理快照/还原、失败降级 |

推送（`git am` 保留作者与 commit message）：

```bash
git remote add fork git@github.com:BysevenOffical/proxypin.git
git fetch origin main

git switch -c fix/linux-build origin/main
git am packaging/arch/pr/0001-fix-linux-build-*.patch
git push fork fix/linux-build

git switch -c fix/linux-runtime origin/main
git am packaging/arch/pr/0001-fix-linux-install-the-root-CA-*.patch \
       packaging/arch/pr/0002-fix-linux-make-window-close-*.patch \
       packaging/arch/pr/0003-fix-linux-handle-the-system-proxy-*.patch
git push fork fix/linux-runtime
```

四个补丁都已验证：对干净 `main` `git apply --check` 通过，全部打上后 `flutter analyze` 只剩改动前
就存在的 4 个 info。

## 三、发 AUR

**已发布**：`proxypin-git`（2026-11-09 推送，维护者 BysevenOffical），git 仓库在
`ssl://aur@aur.archlinux.org/proxypin-git.git`。下面保留打包目录，方便后续更新。

已经准备好的目录：

```
packaging/arch/aur/
├── proxypin-git/     # 推荐先发这个（main 分支 + 修复补丁，已本机验证可运行）
├── proxypin/         # release tag v1.4.0 + 修复补丁（能构建，但见下方注意）
└── proxypin-bin/     # 重打包官方 deb（1.4.0）+ $ORIGIN 修复，作为给现有维护者的 patch
```

发布步骤（`proxypin-git`）：

```bash
# 1) 注册 AUR 账号 + 上传 SSH key 后
git clone ssh://aur@aur.archlinux.org/proxypin-git.git
cp packaging/arch/aur/proxypin-git/{PKGBUILD,.SRCINFO,proxypin-linux-fixes.patch,proxypin.desktop} proxypin-git/
cd proxypin-git
# 2) 先本地验证一遍（.SRCINFO 必须和 PKGBUILD 一致）
makepkg -si
makepkg --printsrcinfo > .SRCINFO
git add -A && git commit -m "Add proxypin-git: HTTP/HTTPS capture tool (VCS, with Linux fixes)"
git push
```

给现有 `proxypin-bin`（别人的包）**不要直接推**，在 AUR 包页面留言贴 diff 即可：

```diff
-pkgver=1.3.3
+pkgver=1.4.0
 pkgrel=1
+  # 插件 RUNPATH 指向上游构建目录，包一旦离开该目录就启动失败
+  find "${pkgdir}/opt/proxypin" -type f -name '*.so' -print0 | xargs -0 -r patchelf --set-rpath '$ORIGIN'
```

### 注意事项

- **AUR 命名**：`-fixed` 这类后缀不符合 AUR 习惯，建议把你现有的 `proxypin-bin-fixed` 废弃/删除，
  内容并入 `proxypin-git`（源码带修复）或作为 patch 提交给 `proxypin-bin`。
- **`proxypin`（release 包）暂时不建议发**：v1.4.0 tag 用当前 Flutter 3.47.9 构建后，我这台机器上
  主窗口停在 `_NET_WM_STATE_HIDDEN`（`window_manager.waitUntilReadyToShow` 的回调没被触发），
  而从 `main` HEAD 构建的版本正常。等上游发新版本（含 tag 之后的 17 个文件修复）再更新 release 包，
  或者顺手把这个现象报给上游。
- `makedepends` 里的 `flutter-bin` 是 AUR 包（3.47.9-1，维护者 xiota），AUR 允许 AUR 包作为
  makedepends；`makepkg -s` / 任意 AUR helper 会自动装。
- `options=('!strip')`：Flutter 自己已经 strip 过，再 strip `libapp.so`/引擎库没有意义。
- 打包时会有一条 `警告：软件包含有对 $srcdir 的引用 usr/lib/proxypin/lib/libapp.so`，这是 AOT 快照里
  的源码路径字符串，无害。
