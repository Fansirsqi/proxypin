# ProxyPin 的 Arch Linux 打包

上游只发布 Linux `.deb`（`linux/build.sh`），这里提供两个 PKGBUILD，产出标准 pacman 包
（`.pkg.tar.zst`），安装位置符合 Arch 习惯（`/usr/lib/proxypin`、`/usr/share/applications`、
`/usr/share/icons`）。

| 目录 | 包名 | 说明 |
| --- | --- | --- |
| `./` | `proxypin` | 从源码编译（Flutter + Rust），与仓库当前 HEAD 一致 |
| `./proxypin-bin/` | `proxypin-bin` | 直接重打包官方 release `.deb`，秒级构建、无需工具链（**上游旧二进制，下面的运行时 bug 仍在**） |

两者互斥（`conflicts`/`provides` 已声明），选一个装即可。

## 快速使用

```bash
# 方式 A：从源码编译（推荐，等于仓库 HEAD 的功能）
cd packaging/arch
makepkg -si

# 方式 B：重打包官方 deb（快，但功能是 v1.4.0 发布时的旧快照）
cd packaging/arch/proxypin-bin
makepkg -si
```

产物：

```bash
sudo pacman -U proxypin-1.4.0-1-x86_64.pkg.tar.zst
# 或
sudo pacman -U proxypin-bin-1.4.0-1-x86_64.pkg.tar.zst
```

安装后：

- 应用菜单里出现 **ProxyPin**，命令行 `proxypin` 也能启动；
- 可执行文件与资源在 `/usr/lib/proxypin/`（`-bin` 版本沿用上游 `/opt/proxypin/`）；
- 配置/证书写在 `~/.proxypin` 与 `~/.local/share/com.network.proxy/`，与卸载互不影响。

## 源码构建依赖（`proxypin`）

`clang cmake ninja pkgconf rust gtk3 patchelf` 都在官方仓库里，**Flutter SDK 不在官方仓库**，
需要 AUR 的 `flutter-bin`（或 `flutter`）：

```bash
paru -S flutter-bin        # 或 yay -S flutter-bin
```

构建时 PKGBUILD 会自动寻找 Flutter：`PATH` → `$FLUTTER_ROOT` → `/opt/flutter` →
`~/flutter` / `~/development/flutter`。Rust 同样支持 pacman 的 `rust` 与 `rustup` 两种安装。

国内网络可在构建时套用镜像：

```bash
FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn \
PUB_HOSTED_URL=https://pub.flutter-io.cn \
makepkg -si
```

离线 / 本地开发机可直接用工作区源码构建（只取 `git HEAD`，未提交改动不会进入包）：

```bash
PROXYPIN_SRC=/path/to/proxypin makepkg -f
```

## 为 Arch 做的修复（`proxypin-arch-build.patch`）

上游代码在 Arch 的滚动工具链上会踩三个坑，补丁已包含全部修复，构建时自动应用：

1. **`tray_manager` 插件编译失败**
   `libayatana-appindicator` 0.6 起把 `app_indicator_*` 标记为 deprecated，而插件用了
   `-Werror`，clang 19+ / gcc 15+ 直接报错。补丁加 `-Wno-error=deprecated-declarations`。

2. **`code_forge`（Rust FFI 插件）加载失败**
   新版 Flutter 引擎不再从 `libflutter_linux_gtk.so` 导出 `Dart_*` 符号，运行时报
   `Failed to load dynamic library 'libcode_forge.so': undefined symbol: Dart_CurrentIsolate_DL`，
   编辑器相关功能（请求体 / 脚本 / 重写编辑器）静默降级。
   补丁把 Dart SDK 的 `dart_api_dl.c` 编进主程序并 `-Wl,--export-dynamic`，插件即可正常初始化。
   路径由 `PROXYPIN_DART_API_DL_C` 传入，未设置时 CMake 自动从 `PATH` 上的 `flutter` 推导。

3. **窗口图标路径写死 `/opt/proxypin`**
   `linux/my_application.cc` 的 release 分支硬编码 Debian 安装路径；补丁改为按
   `/proc/self/exe` 解析 `data/flutter_assets/assets/icon.png`，任意 prefix 都可用。

## 运行时修复（必须在应用代码里改，已包含在上面的补丁里）

上游 Linux 版还有两个真实影响使用的 bug，这个补丁一并修好：

4. **「安装证书」不会提权，装不上**
   `cert_installer.dart` 直接 `cp` 到 `/usr/local/share/ca-certificates/` 再跑
   `update-ca-certificates`，普通用户必然失败；而且 Arch 上根本没有这个命令
   （Arch/Fedora 走的是 p11-kit 的 `trust extract-compat`，`/usr/local/share/ca-certificates`
   这个目录都不存在）。现在按发行版自动识别 CA 库，并通过 `pkexec` 弹一次
   polkit 授权框完成「拷贝 + 刷新」，装完还会顺带写入 Chrome/Chromium 的 NSS 用户库
   （`~/.pki/nssdb`）。手动页签也补了 Arch/Fedora/openSUSE 的命令。

5. **点 ❌ 关不掉、进程只能 `pkill`**
   两个叠加原因：
   - `tray_manager` 的 Linux 实现**没有实现 `setToolTip`**，`DesktopTrayManager`
     初始化时抛 `MissingPluginException`，于是“最小化到托盘”永远走失败分支；
   - 失败后走的 `appExit()` 里 `await windowManager.destroy()` 在 KDE Wayland 上
     有时**永不返回**，窗口没了但进程残留，只能 `pkill proxypin`。
   修复：tooltip 调用容错（Linux 跳过）、托盘图标改成真实 PNG 路径、`hide()` 后校验是否
   真的藏起来了（藏不住就直接退出而不是假装成功）、退出流程不再 `await` 窗口销毁
   （`exit(0)` 兜底）、停止代理加 3 秒超时、退出加防重入。

   实测（KDE Wayland + XWayland）：选「最小化到托盘」→ 窗口隐藏、托盘图标出现、
   可从托盘「显示窗口/退出」；选「退出」→ 进程 1 秒内退出，不再需要 pkill。

6. **「停止」显示已停止但代理还在监听 / 提示失败（Plasma 6）**
   `proxy_manager` 0.0.3 在 `XDG_CURRENT_DESKTOP=KDE` 时用 `kwriteconfig5` 写
   `~/.config/kioslaverc`，而 **Plasma 6 只有 `kwriteconfig6`** → `ProcessException`：
   - `ProxyServer.stop()` 里异常发生在 `server.stop()` 之前 → 系统代理没恢复、监听没关，
     UI 却已经切成「已停止」，同时弹「失败」吐司；
   - 启动时 `setSystemProxyEnable(true)` 抛的是未处理异步异常（不影响监听，但系统代理没设全）。
   现在 Linux 系统代理自己实现：gsettings + `kwriteconfig6`（回退 `kwriteconfig5`），
   工具缺失只记日志；并且 `start()`/`stop()` 里把系统代理失败降级为非致命，代理本体永远能起停。

7. **每次「停止」都会把用户的系统代理配置清成 `none`**
   上游 `cleanSystemProxy()` 只是把模式设成 `none`，所以你的 Clash Verge PAC / GNOME 手动代理
   每停机一次就丢一次。现在启动系统代理前先把用户原配置快照到
   `~/.proxypin/system_proxy_backup.json`（gsettings 的 mode / autoconfig-url / ignore-hosts
   以及 `.http` `.https` `.socks` 三个 schema 的 enabled/host/port，外加 KIO 的 `[Proxy Settings]`），
   停止时原样还原；用户原本没有的键会被删掉，代理运行期间 socks 会被临时关闭（停止后还原）。
   没有备份文件时（系统代理不是我们开的）仍走旧的「关掉代理」逻辑。

8. **启动后右上角没有托盘图标**
   上游只在「关闭时最小化到托盘」那一刻才初始化托盘，所以正常启动后系统托盘里
   根本看不到 ProxyPin，也没有「显示窗口/退出」菜单入口。现在桌面端启动即注册托盘图标。

另外封装阶段还修了 Flutter 打包自身的一个坑：`zstandard_linux` 插件链接的
`libzstandard_linux.so` 不会被 `flutter build linux` 拷进 bundle，且插件 `RUNPATH`
指向构建目录。`package()` 会补上该库并把所有 `*.so` 的 `RUNPATH` 归一化为 `$ORIGIN`，
否则包一旦离开构建目录就启动失败。

## Fedora / RHEL 的 RPM 包

同一份 bundle 也能打成 RPM（无需在 Fedora 上装 Flutter）：见 `../rpm/README.md`。

```bash
cd packaging/rpm && ./build-rpm.sh
# 产物 dist/x86_64/proxypin-1.4.0-1.fc43.x86_64.rpm，Fedora 上 dnf install 即可
```

注意 Fedora 的根证书目录是 `/etc/pki/ca-trust/source/anchors`（刷新命令 `update-ca-trust extract`），
补丁里已经按发行版自动识别；`GLIBC_2.34` 基线要求 Fedora 38+ / RHEL 10+。

## 说明

- 包名 `proxypin` / `proxypin-bin` 与 AUR 上同名包冲突，若要上传 AUR 请先确认命名。
- 打包脚本不修改上游发布流程；`.deb` 打包逻辑（`linux/build.sh`）保持原样。
- 冒烟测试：把包解包后在 KDE Wayland 上真机跑过 —— 启动、代理监听、CA 生成、
  关闭/退出、最小化到托盘都验证过；但 `/usr/bin/proxypin` 软链只有在真正
  `pacman -U` 安装后才生效。
- 若要让这些运行时修复进上游，可直接把 `lib/` 下四个文件的改动单独提 PR，
  PKGBUILD 里的补丁只是打包用的临时载体。
