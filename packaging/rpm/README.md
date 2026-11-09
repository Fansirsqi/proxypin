# ProxyPin 的 Fedora / RHEL 打包（RPM）

上游同样只提供 `.deb`。这里用 **已经构建好的 Flutter bundle** 打标准 RPM，所以不需要在 Fedora 上装
Flutter SDK 和 Rust——产物里的二进制与 Arch 包是同一份（`GLIBC_2.34` 基线，Fedora 38+ / RHEL 10 都能跑）。

```bash
cd packaging/rpm
./build-rpm.sh                 # 复用 build/linux/x64/release/bundle
./build-rpm.sh --build         # 先 flutter build linux --release 再打包
BUNDLE=/path/to/bundle ./build-rpm.sh
FEDORA_IMAGE=fedora:42 ./build-rpm.sh   # 指定目标 Fedora 版本（决定 .fcXX 后缀）
```

产物：`dist/x86_64/proxypin-1.4.0-1.fc43.x86_64.rpm`

```bash
sudo dnf install ./proxypin-1.4.0-1.fc43.x86_64.rpm
proxypin        # 或从应用菜单启动
```

## 构建方式

`build-rpm.sh` 会：

1. 把 bundle 拷到 `proxypin-<ver>/bundle/`；
2. 补上 Flutter 不会打包的 `libzstandard_linux.so`，并把所有 `*.so` 的 `RUNPATH` 归一化成 `$ORIGIN`
   （和 Arch 包同一套修复，否则包一离开构建目录就启动失败）；
3. 打 tarball，然后调用 `rpmbuild`：
   - 本机有 `rpm-build` → 直接跑（Fedora 上 `sudo dnf install rpm-build patchelf`）；
   - 没有（例如 Arch）→ 自动用 docker 里的 Fedora 容器跑，并以你的 uid 产出文件。

## 安装布局

```
/usr/bin/proxypin                         -> /usr/lib64/proxypin/ProxyPin
/usr/lib64/proxypin/{ProxyPin,data,lib}
/usr/share/applications/proxypin.desktop
/usr/share/icons/hicolor/256x256/apps/proxypin.png
/usr/share/licenses/proxypin/LICENSE
```

依赖（RPM 自动 + 显式）：`gtk3`、`libayatana-appindicator-gtk3`、`ca-certificates`、`hicolor-icon-theme`、
`polkit`（"安装证书"要用 `pkexec` 提权）；建议装 `xdg-desktop-portal`（原生文件选择框）。

## 与 deb/Arch 包共有的修复

- **证书安装**：Fedora 走 `/etc/pki/ca-trust/source/anchors` + `update-ca-trust extract`
  （Arch 走 p11-kit、Debian 走 `update-ca-certificates`），都用一次 `pkexec` 提权；顺带写入
  Chrome/Chromium 的 NSS 用户库。
- **托盘/退出**：启动即注册托盘图标、`setToolTip` 缺失容错、`hide()` 后校验、退出不 `await` 窗口销毁。
- **系统代理**：Plasma 6 用 `kwriteconfig6`（回退 `kwriteconfig5`），启用前快照用户配置、停止后原样还原。

## 注意

- `spec` 里 `%global __os_install_post %{nil}` 关掉了 brp-strip：Flutter 的 `libapp.so` 已经 strip 过，
  再次 strip 会破坏 AOT 快照。
- 打包时 rpmbuild 会提示 `absolute symlink: /usr/bin/proxypin -> /usr/lib64/proxypin/ProxyPin`，
  这是刻意的（与 deb/Arch 一致），不是错误。
- 32 位 ARM / aarch64 不在此 spec 范围内（`BuildArch: x86_64`）。
- bundle 是用 Arch 的 clang 编译的，最高只要求 `GLIBC_2.34`；如果以后在更新的发行版上重新编译，
  记得复查 `objdump -T <bin> | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1`，别把 glibc 基线推高。
