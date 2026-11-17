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

上游没有双语 PR 的先例，但维护者是中文母语、仓库面向国际用户，所以统一用**分段双语**：
标题写 `中文 / English`，段内中文一句、英文一句紧跟着，不做两份重复正文——同样的信息量下篇幅只有
「英文正文 + 中文摘要」的一半。

### PR 正文（双语，2026-11-17 已同步到 GitHub）

格式：每段标题用 `中文 / English`，段内先中文一句、再英文一句；标题只用「问题 / 改动 / 验证」三段，
长表格最多留一张改前/改后对照。这样 PR 整体 20~30 行，中英读者都能扫完。

#996 `fix/linux-build`：

````markdown
### 问题 / Problem

Arch / CachyOS（clang 19+、libayatana-appindicator 0.6、Flutter 3.44+）上源码构建失败，且构建出来的包功能残缺。

On Arch/CachyOS (clang 19+, libayatana-appindicator 0.6, Flutter 3.44+) the source build fails, and the resulting package is degraded.

1. `tray_manager` 编译失败：`app_indicator_new` 被标记 deprecated，插件带 `-Werror`。
2. 运行时 `Failed to load dynamic library 'libcode_forge.so': undefined symbol: Dart_CurrentIsolate_DL`，编辑器相关功能静默失效。
3. release 窗口图标写死 `/opt/proxypin/...`（Debian 布局），其它安装 prefix 没有图标。

### 改动 / Changes

- `linux/CMakeLists.txt`
  - deprecated 声明不再 `-Werror`（仅为兼容现有 tray_manager；升到 0.8.x 后可去掉）。
  - 把 Dart SDK 的 `dart_api_dl.c` 编进 runner 并 `-Wl,--export-dynamic`，FFI 插件即可解析 `Dart_*` 符号（路径可用 `PROXYPIN_DART_API_DL_C` 指定，默认从 `flutter` 推导）。
- `linux/my_application.cc`：图标按 `/proc/self/exe` 解析，任意 prefix 可用。

### 验证 / Verification

- Arch + Flutter 3.47.9 + clang 23：`flutter build linux --release` 通过；产物导出 45 个 `Dart_*` 符号，运行日志不再有 `RustLib.init failed`。
- Verified on Arch with Flutter 3.47.9 / clang 23: the release build succeeds, the binary exports 45 `Dart_*` symbols and `RustLib.init failed` no longer appears.
````

#997 `fix/linux-runtime`：

````markdown
### 问题 / Problem

KDE Plasma 6（Wayland + XWayland）上三个影响使用的问题：

Three user-visible Linux bugs on Plasma 6 (Wayland + XWayland):

1. **安装证书失败**：Linux 分支 `cp` 到 `/usr/local/share/ca-certificates` + `update-ca-certificates`，普通用户无权限；Arch/Fedora 根本没这个命令（走 p11-kit / `update-ca-trust`），目录也不存在。
   **CA install fails**: the Linux branch copies the CA to a root-owned dir and runs a command that doesn't exist on Arch/Fedora.
2. **点 ❌ 关不掉**：`tray_manager` 的 Linux 实现没有 `setToolTip`，托盘初始化抛 `MissingPluginException`；随后 `await windowManager.destroy()` 在 Wayland 上不返回，进程残留只能 `pkill`。另外托盘图标只在关闭时才初始化，启动后系统托盘里看不到图标。
   **Close/quit broken**: `setToolTip` is missing on Linux so tray init throws, and the fallback `await destroy()` never returns on Wayland.
3. **Plasma 6「停止」报失败、端口仍在监听**：`proxy_manager` 0.0.3 写死 `kwriteconfig5`（Plasma 6 只有 `kwriteconfig6`）抛异常，异常发生在 `server.stop()` 之前；同时停止会把用户 PAC / 手动代理配置清成 `mode=none`。
   **Stop fails on Plasma 6**: `proxy_manager` calls the removed `kwriteconfig5`, and stopping wipes the user's proxy configuration.

### 改动 / Changes

- `cert_installer.dart` / `pc_cert.dart`：按发行版识别信任库（Debian、p11-kit、Fedora `update-ca-trust`），用一次 `pkexec` 完成拷贝+刷新；顺带写入 Chrome 的 NSS 用户库（`~/.pki/nssdb`）。
- `desktop_tray.dart` / `launch.dart`：启动即注册托盘；tooltip 缺失容错；`hide()` 后校验是否真的隐藏；退出不再 `await` 窗口销毁（`exit(0)` 兜底），停代理加超时、退出防重入。
- `system_proxy.dart` / `server.dart`：gsettings + `kwriteconfig6`（回退 `kwriteconfig5`）；启用前快照用户配置，停止时还原（用户原本没有的键删除）；系统代理失败降级为日志，不再影响代理启停。

### 验证 / Verification

| | 修复前 / Before | 修复后 / After |
| --- | --- | --- |
| 安装证书 | 静默失败 | polkit 授权后写入系统库 + NSS |
| 启动后托盘 | 无图标 | 启动即有图标（显示窗口 / 退出） |
| 关闭 → 退出 | 窗口消失、进程残留 | 1 秒内退出 |
| 点「停止」 | 弹失败、端口仍监听 | 端口立即关闭 |
| 停止后的系统代理 | `mode=none`，PAC 丢失 | 原样还原 |
````

#1000 `feat/ui-settings-and-fonts`：

````markdown
### 说明 / Summary

抓包列表密度、代码字体、界面字体/字号这几项目前是写死的，这里做成设置项（桌面 + 移动端都有入口）。

Capture list density, code font and interface font/size are hard-coded today; this adds settings for them (entries on both desktop and mobile).

### 改动 / Changes

- `configuration.dart`：新增 `captureListDensity` / `editorFontFamily` / `editorFontSize` / `appFontFamily` / `appFontScale` / `visualDensity`，随 `ui_config.json` 持久化。
- `lib/ui/component/code_style.dart`（新增）：代码区域的统一文本样式与 `CaptureRowMetrics`，供列表行高、行内代码、toolbox 复用。
- `app_appearance_setting.dart` / `code_font_setting.dart`（新增）+ `preference.dart`：设置界面；`system_fonts.dart` 负责枚举系统等宽字体。
- 各语言 `.arb` 增加对应文案。

### 验证 / Verification

- `flutter analyze`：0 error / 0 warning（桌面 + 移动端入口都能正常打开并持久化）。
- Verified with `flutter analyze` (0 errors / 0 warnings); settings persist to `ui_config.json` and apply immediately.
````

#999（已关闭）关闭说明，同时贴在评论里：

````markdown
Contents of this PR are fully contained in #1000 (same 4 commits), and it does not compile on its own:
`code_style.dart` / `CaptureRowMetrics` / `codeTextStyle` only exist in the settings commit of #1000.

本 PR 的 4 个提交全部包含在 #1000 中，且单独编译不过（`code_style.dart` 等只存在于 #1000 的设置提交里）。
关闭，改为在 #1000 里统一 review。
````

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
