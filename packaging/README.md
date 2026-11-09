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

## GitHub Actions

`.github/workflows/linux-packages.yml`：

- `tag` 推送（`v*`）→ 构建 Arch + RPM 并挂到该 tag 的 Release；
- `workflow_dispatch` → 手动构建；`tag` 输入留空只产 artifact，填了就发布。

```bash
git tag v1.4.0-linux.1 && git push origin v1.4.0-linux.1   # 在你的 fork 上打 tag
```

注意：CI 放在 fork 自己的 `main` 上（上游不接受打包 CI），PR #996 / #997 里不含这个 workflow。
