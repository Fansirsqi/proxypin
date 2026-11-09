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

### PR 1 正文草稿

```markdown
### 现象
Arch/CachyOS（clang 19+/gcc 15+、libayatana-appindicator 0.6、Flutter 3.47）上无法构建，或构建出来的包功能降级：

1. `tray_manager` 插件编译失败：`app_indicator_new` 被标记 deprecated，插件带 `-Werror`。
2. 运行时报 `Failed to load dynamic library 'libcode_forge.so': undefined symbol: Dart_CurrentIsolate_DL`，编辑器相关功能（请求体/脚本/重写编辑器）静默失效——新引擎不再从 `libflutter_linux_gtk.so` 导出 `Dart_*`。
3. release 窗口图标路径写死 `/opt/proxypin/...`（Debian 布局），非 deb 安装方式取不到图标。

### 改动
- `linux/CMakeLists.txt`
  - 对 deprecated 告警不再 `-Werror`（只为兼容 tray_manager 现有代码）。
  - 把 Dart SDK 的 `dart_api_dl.c` 编进宿主程序并 `-Wl,--export-dynamic`，FFI 插件即可解析 `Dart_InitializeApiDL` 等符号；路径可由 `PROXYPIN_DART_API_DL_C` 指定，缺省时从 PATH 上的 `flutter` 推断。
- `linux/my_application.cc`：按 `/proc/self/exe` 解析 `data/flutter_assets/assets/icon.png`。

### 验证
- Arch/CachyOS + Flutter 3.47.9 + clang 23：`flutter build linux --release` 通过；
- 包内 `ProxyPin` 导出 45 个 `Dart_*` 符号，运行日志不再出现 `RustLib.init failed`。
```

### PR 2 正文草稿

```markdown
### 现象（KDE Wayland + XWayland 实测）
1. 点「安装证书」→ 直接失败（Linux 分支用 `cp /usr/local/share/ca-certificates/` + `update-ca-certificates`）：
   - 普通用户无权限，异常被吞掉只弹“安装失败”；
   - Arch/Fedora 根本没有 `update-ca-certificates`（走 p11-kit `trust extract-compat`），该目录也不存在。
2. 点 ❌ 关闭窗口 → 没有任何反应，进程只能 `pkill`。根因是两个 bug 叠加：
   - `tray_manager` 的 Linux 实现**没有 `setToolTip`** → `DesktopTrayManager.ensureInitialized()` 抛
     `MissingPluginException(No implementation found for method setToolTip on channel tray_manager)` →
     “最小化到托盘”永远失败；
   - 失败后走 `appExit()`，其中 `await windowManager.destroy()` 在 KDE Wayland 上**永不返回**，
     窗口已销毁但进程残留。

### 改动
- `cert_installer.dart`：按发行版识别 CA 库（Debian `update-ca-certificates` / p11-kit `trust extract-compat`），
  用 `pkexec sh -c 'install -Dm644 "$1" "$2" && <refresh>'` 一次提权完成拷贝+刷新；装完顺带写入
  Chrome/Chromium 的 NSS 用户库（`~/.pki/nssdb`，用户级无需提权）；证书落盘名固定为 `proxypin-ca.crt`。
  `isCertInstalled` 同时检查 p11-kit / Debian / openSUSE / `/etc/ssl/certs` 四个位置。
- `pc_cert.dart`：Linux 手动页签补 Arch/Fedora/openSUSE 的命令，并说明自动安装走 polkit。
- `desktop_tray.dart`：tooltip 调用容错；托盘图标改用 bundle 内 PNG（AppIndicator 只认真实文件）；
  `hide()` 后校验窗口是否真的隐藏，隐藏失败就返回 false。
- `system_proxy.dart`：Linux 分支不再依赖 `proxy_manager` 的 KDE 实现（它写死 `kwriteconfig5`，
  Plasma 6 上抛异常），改为 gsettings + `kwriteconfig6`/`kwriteconfig5` 回退；`server.dart` 里
  系统代理失败降级为日志。
- `launch.dart`：桌面端**启动即初始化托盘图标**（上游只在关闭时懒加载，正常启动后系统托盘里没有
  图标、也找不到「显示窗口/退出」入口）；托盘不可用/隐藏失败时直接退出而不是假装成功；
  `appExit()` 不再 `await` 窗口销毁（`exit(0)` 兜底）、停代理加 3 秒超时、退出流程加防重入。

### 系统代理（Plasma 6）
`proxy_manager` 0.0.3 在 `XDG_CURRENT_DESKTOP=KDE` 时调用 `kwriteconfig5`，Plasma 6 只有
`kwriteconfig6` → `ProcessException`：点「停止」后 UI 显示已停止、监听其实还在、并弹「失败」吐司
（异常在 `ProxyServer.stop()` 里发生在 `server.stop()` 之前）。本 PR 在 `system_proxy.dart` 里
自己实现 Linux 的 gsettings + `kwriteconfig6`（回退 `kwriteconfig5`），并让
`ProxyServer.start()/stop()` 把系统代理失败降级为日志，不再影响代理启停。

### 系统代理配置不再被清空
上游 `cleanSystemProxy()` 直接把模式置为 `none`，会连带清掉用户的 PAC / 手动代理配置。本 PR 在
启用前把 gsettings（mode / autoconfig-url / ignore-hosts + 各协议的 enabled/host/port）和 KIO
`[Proxy Settings]` 快照到 `~/.proxypin/system_proxy_backup.json`，停止时还原（用户原本没有的键
删除），运行期间临时关闭 socks；没有快照时保持旧行为。

### 验证（KDE Wayland + XWayland）
| 操作 | 修复前 | 修复后 |
| --- | --- | --- |
| 关闭 → 最小化到托盘 | 抛 MissingPluginException，随后进程残留 | 窗口隐藏、托盘条目注册成功 |
| 关闭 → 退出 | 窗口消失但进程残留，只能 pkill | 1 秒内退出 |
| 安装证书 | 静默失败 | 弹 polkit 授权框，成功后系统库 + NSS 库均有 |
| 启动后系统托盘 | 无图标 | 启动即出现图标，菜单可「显示窗口/退出」 |
| 点「停止」 | 弹「失败」，端口仍在监听 | 端口立即关闭，无吐司 |
| 停止后的系统代理 | 变成 `mode=none`，PAC 丢失 | 原样还原（PAC URL / 端口 / kioslaverc 全部恢复） |

### 可选的更彻底方案
`tray_manager` 已经到 0.8.x（本项目锁 0.5.3），新版本 Linux 端用 `libayatana-appindicator-glib`
并实现了 `setToolTip`；`window_manager` 也有 0.6.0。如果愿意做依赖升级，本 PR 的 1、2 两个 workaround
可以分别退化成一次版本 bump（需要适配 `menu_base` 的 API 变化并重测）。
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
