# 由已构建好的 Flutter bundle 直接打成 RPM（不需要在 Fedora 上装 Flutter/Rust）。
# 用法见 packaging/rpm/README.md：
#   ./build-rpm.sh            # 复用 build/linux/x64/release/bundle
%global debug_package %{nil}
# Flutter 的引擎/AOT 库已经 strip 过，brp-strip 会破坏 libapp.so，直接跳过整段 os_install_post
%global __os_install_post %{nil}

Name:           proxypin
Version:        1.4.0
Release:        1%{?dist}
Summary:        HTTP/HTTPS packet capture and manipulation tool with an in-process MITM proxy
License:        Apache-2.0
URL:            https://github.com/wanghongenpin/proxypin
Source0:        %{name}-%{version}-bundle.tar.gz
Source1:        proxypin.desktop
Source2:        LICENSE
BuildArch:      x86_64
Requires:       gtk3
Requires:       libayatana-appindicator-gtk3
Requires:       ca-certificates
Requires:       hicolor-icon-theme
Requires:       polkit
Recommends:     xdg-desktop-portal

%description
ProxyPin is a free and open source HTTP(S) capture tool. It runs an in-process
MITM proxy, installs its own CA certificate and lets you inspect, rewrite and
script traffic from a desktop UI.

This build is compiled from the upstream sources plus Linux fixes (system CA
installation through polkit, tray/quit behaviour, Plasma 6 system proxy
handling) and ships the Flutter bundle as-is.

%prep
%setup -q

%build

%install
rm -rf %{buildroot}
install -d %{buildroot}%{_libdir}/proxypin
cp -a bundle/. %{buildroot}%{_libdir}/proxypin/

install -d %{buildroot}%{_bindir}
ln -s %{_libdir}/proxypin/ProxyPin %{buildroot}%{_bindir}/proxypin

install -Dpm644 %{SOURCE1} %{buildroot}%{_datadir}/applications/proxypin.desktop
install -Dpm644 bundle/data/flutter_assets/assets/icon.png \
    %{buildroot}%{_datadir}/icons/hicolor/256x256/apps/proxypin.png
install -Dpm644 %{SOURCE2} %{buildroot}%{_licensedir}/%{name}/LICENSE

%files
%license %{_licensedir}/%{name}/LICENSE
%{_bindir}/proxypin
%{_libdir}/proxypin
%{_datadir}/applications/proxypin.desktop
%{_datadir}/icons/hicolor/256x256/apps/proxypin.png

%changelog
* Mon Nov 09 2026 Fansirsqi <38542005+Fansirsqi@users.noreply.github.com> - 1.4.0-1
- Initial RPM packaging of the Flutter bundle with Linux fixes
