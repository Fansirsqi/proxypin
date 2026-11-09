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

### PR 正文（英文，已更新到 #996 / #997）

PR 1（`fix/linux-build`）：

```markdown
### Problem

Building on Linux with current toolchains fails, or ships a degraded app:

- `tray_manager` still calls the deprecated `app_indicator_*` API and is compiled with `-Werror`, so clang 19 / gcc 15 abort the build with libayatana-appindicator 0.6.
- `libcode_forge.so` fails with `undefined symbol: Dart_CurrentIsolate_DL`. Current engines no longer export `Dart_*` from `libflutter_linux_gtk.so`, so `RustLib.init()` fails and the editor features silently degrade.
- The release window icon is hardcoded to `/opt/proxypin/...` (Debian layout), so any other install prefix gets a GTK warning and no icon.

### Changes

- `linux/CMakeLists.txt`: do not treat deprecated-declaration warnings as errors; compile the Dart SDK's `dart_api_dl.c` into the runner and export the dynamic symbol table (SDK path from `PROXYPIN_DART_API_DL_C`, otherwise derived from `flutter` on `PATH`).
- `linux/my_application.cc`: resolve the icon relative to `/proc/self/exe`.

### Testing

- `flutter build linux --release` on Arch/CachyOS, Flutter 3.47.9 + clang 23.
- The binary exports 45 `Dart_*` symbols and no longer logs `RustLib.init failed`.
- Installed under `/usr/lib/proxypin`: icon loads, no GTK warning.
```

PR 2（`fix/linux-runtime`，3 个 commit）：

```markdown
### Problem

Three Linux runtime issues, reproduced on KDE Plasma 6 (Wayland):

1. **Install certificate** fails silently. The Linux branch copies the CA to `/usr/local/share/ca-certificates` and runs `update-ca-certificates` as a normal user, which needs root; on Arch/Fedora neither the command nor the directory exists (p11-kit / `update-ca-trust` is used).
2. **Closing the window** does nothing and the process can only be killed with `pkill`:
   - `tray_manager` has no Linux `setToolTip`, so `DesktopTrayManager.ensureInitialized()` throws `MissingPluginException` and "minimize to tray" never works;
   - the fallback then awaits `windowManager.destroy()`, which never returns on KDE/Wayland: the window is gone, the process stays, and `setPreventClose(true)` makes the window impossible to close.
3. **Stop** reports a failure while the listener keeps running, and every stop wipes the user's proxy configuration:
   - `proxy_manager 0.0.3` runs `kwriteconfig5`, which Plasma 6 removed (`kwriteconfig6`), so `stop()` throws before `server.stop()`;
   - `cleanSystemProxy()` sets `mode=none`, discarding PAC / manual settings.

### Changes

- `cert_installer.dart`, `pc_cert.dart`: detect the trust store per distribution (p11-kit, Debian, Fedora `update-ca-trust`), install and refresh in one `pkexec sh -c ...` call so polkit prompts once; also add the CA to the NSS user DB (`~/.pki/nssdb`) for Chrome/Chromium; anchor is written as `proxypin-ca.crt`.
- `desktop_tray.dart`, `launch.dart`: initialize the tray at startup (upstream only does it on the first "minimize to tray" close, so a normal start has no tray icon at all), tolerate the missing tooltip, use a bundled PNG for AppIndicator, verify that `hide()` actually hid the window, and exit without awaiting window destruction (proxy shutdown timeout, re-entry guard).
- `system_proxy.dart`, `server.dart`: handle the Linux system proxy locally with `kwriteconfig6` (fallback `kwriteconfig5`), snapshot the previous gsettings/KIO values to `~/.proxypin/system_proxy_backup.json` and restore them on stop (keys that did not exist are removed), and treat system-proxy failures as non-fatal in `start()` / `stop()`.

### Testing

| Action | Before | After |
| --- | --- | --- |
| Install certificate | silent failure, no prompt | polkit prompt, anchor + NSS DB written |
| Tray icon after launch | none | present at startup, with Show/Quit menu |
| Close → minimize to tray | exception, then leftover process | window hidden, tray item registered, restorable |
| Close → quit | window gone, process alive (`pkill`) | exits within a second |
| Stop button | failure toast, port still listening | port closed, no toast |
| System proxy after stop | `mode=none`, PAC lost | original PAC URL / ports / kioslaverc restored |

`flutter analyze` reports no new issues; the 5 failing `flutter test`s fail on unpatched `main` as well (dependency resolution), unrelated to this PR.

Bumping `tray_manager` to 0.8.x would replace the first two workarounds (`libayatana-appindicator-glib` + `setToolTip`); I can open that as a separate PR if you prefer.
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
