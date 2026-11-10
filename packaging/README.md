# 打包目录总览

上游只发布 `.deb`，这里提供 Arch/CachyOS 与 Fedora/RHEL 的打包，以及把它们挂到 GitHub Release 的 CI。

| 目录 | 产物 | 说明 |
| --- | --- | --- |
| `arch/` | `proxypin-<ver>-1-x86_64.pkg.tar.zst` | 从源码构建（需 Flutter SDK + Rust），落盘到 `/usr/lib/proxypin` |
| `arch/aur/proxypin-git/` | AUR 包 | **我们唯一维护的 AUR 包**：从 `main` 构建 + 打补丁，CI 自动同步 |
| `arch/pr/` | 上游 PR 补丁 | 4 个 `git format-patch` 文件，对应 PR #996 / #997 |
| `rpm/` | `proxypin-<ver>-1.fcXX.x86_64.rpm` | 复用已构建的 bundle 打 RPM，落盘到 `/usr/lib64/proxypin` |

## 所有包共用的 Linux 修复

补丁在 `arch/proxypin-linux-fixes.patch`（AUR 与 RPM 都基于它），内容：

1. Arch 工具链上 `tray_manager` 因 deprecated API + `-Werror` 编译失败；
2. 新版引擎不导出 `Dart_*`，`code_forge` FFI 插件加载失败（`dart_api_dl.c` + `--export-dynamic`）；
3. release 窗口图标写死 `/opt/proxypin`；
4. 「安装证书」不提权、Fedora/Arch 的 trust store 路径不认（现在 pkexec + Debian/p11-kit/Fedora 三套路径 + Chrome NSS 库）；
5. 点 ❌ 关不掉、进程只能 `pkill`（tooltip 缺失容错、hide 校验、退出不 `await` 销毁）；
6. 启动后系统托盘没有图标（改为启动即注册）；
7. Plasma 6 上「停止」报失败且端口仍在监听（`kwriteconfig5` 缺失）+ 停止会清空用户 PAC（改为快照/还原）。

## 额外的本地增强（不进上游 PR）

除了上面的 Linux 修复，这套补丁还带两个界面设置（上游目前没有）：

| 设置 | 位置 | 说明 |
| --- | --- | --- |
| 抓包列表密度 | 偏好设置 → 抓包列表密度 | 宽松（默认，保持原样）/ 紧凑（约 53px → 36px）/ 极紧凑（单行，约 19px，隐藏第二行） |
| 代码字体 / 字号 | 偏好设置 → 代码字体 / 代码字号 | 作用于请求体、响应体、脚本编辑器等代码窗口；字体族在 Linux 上通过 `fc-list :spacing=mono` 枚举，另提供常见字体列表与自定义输入 |
| 界面字体 / 字号 | 偏好设置 → 界面字体 / 界面字号 | 整个界面（代码窗口除外）的字体与缩放，字体族通过 `fc-list` 枚举 |
| 界面密度 | 偏好设置 → 界面密度 | 按钮/列表/菜单的间距（`ThemeData.visualDensity`），和「抓包列表密度」是两项不同设置 |

存到 `~/.proxypin/ui_config.json` 的 `captureListDensity` / `editorFontFamily` / `editorFontSize` /
`appFontFamily` / `appFontScale` / `uiDensity`。

**Linux 行为差异**：Impeller 后端下同一进程里的第二个 FlutterEngine 拿不到 GL 上下文（子窗口空白、
关闭时 GLX 报 `BadAccess` 直接把进程 abort），所以 Linux 上工具箱工具、脚本/重写编辑器等都改成
**在主窗口内以路由打开**：只有一层标题栏，顶部 40px 是拖动区（主窗口无边框），页面自带返回键。
Windows/macOS 仍然开独立子窗口。

窗口是无边框的（`TitleBarStyle.hidden`），所以窗口管理器不再提供边缘 resize 热区；
补丁在 `MaterialApp.builder` 外面套了 `WindowResizeBorder`（四条边 + 四个角各 4px 透明热区，
按下即 `windowManager.startResizing(edge)`，光标形状跟着变），并显式 `setResizable(true)`。

打包时还兜底装了一个 Flutter 自己会漏掉的库：`flutter_js` 的预编译
`libquickjs_c_bridge_plugin.so`（干净构建时插件会把它装到错误的前缀，运行时报
`Failed to load dynamic library 'libquickjs_c_bridge_plugin.so'`，JS 工具与脚本拦截器全挂）。

## GitHub Actions

`.github/workflows/linux-packages.yml`：

- `tag` 推送（`v*`）→ 构建 Arch + RPM 并挂到该 tag 的 Release；
- `workflow_dispatch` → 手动构建；`tag` 输入留空只产 artifact，填了就发布。

```bash
git tag v1.4.0-linux.1 && git push origin v1.4.0-linux.1   # 在你的 fork 上打 tag
```

注意：CI 放在 fork 自己的 `main` 上（上游不接受打包 CI），PR #996 / #997 里不含这个 workflow。
