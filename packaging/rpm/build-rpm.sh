#!/bin/bash
# 把已经构建好的 Flutter bundle 打成 Fedora/RHEL 的 RPM。
#
#   ./build-rpm.sh                     # 复用 ../..//build/linux/x64/release/bundle
#   BUNDLE=/path/to/bundle ./build-rpm.sh
#   FLUTTER_BIN=/opt/flutter/bin/flutter ./build-rpm.sh --build   # 先重新编译
#
# 在 Arch 上也能跑：通过 docker 里的 Fedora 容器调用 rpmbuild（需要 docker + 联网）。
# 在 Fedora 本机上直接跑则需要 rpm-build（dnf install rpm-build patchelf）。
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
VERSION=$(grep '^version:' "$REPO/pubspec.yaml" | sed 's/version: //; s/+.*//')
BUNDLE=${BUNDLE:-$REPO/build/linux/x64/release/bundle}
OUT=${OUT:-$HERE/dist}
FEDORA_IMAGE=${FEDORA_IMAGE:-fedora:43}

if [[ ${1:-} == "--build" ]]; then
  FLUTTER_BIN=${FLUTTER_BIN:-flutter}
  echo "==> flutter build linux --release"
  ( cd "$REPO" && "$FLUTTER_BIN" build linux --release )
fi

[[ -x $BUNDLE/ProxyPin ]] || { echo "找不到 bundle：$BUNDLE（先 flutter build linux --release）" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
top=$work/proxypin-$VERSION
mkdir -p "$top"
cp -a "$BUNDLE" "$top/bundle"

# Flutter 不会把 zstandard_linux 依赖的 .so 拷进 bundle，且插件 RUNPATH 指向构建目录；
# 不修的话包一离开构建目录就启动失败（与 Arch 包同一套处理）。
zstd=$(find "$REPO/build/linux/x64/release/plugins/zstandard_linux" -name 'libzstandard_linux.so' 2>/dev/null | head -1)
if [[ -n $zstd ]]; then
  cp -f "$zstd" "$top/bundle/lib/"
fi
if command -v patchelf >/dev/null; then
  find "$top/bundle" -name '*.so*' -type f -print0 | xargs -0 -r patchelf --set-rpath '$ORIGIN'
else
  echo "警告：没有 patchelf，bundle 里的 RUNPATH 可能指向构建目录" >&2
fi

tar -C "$work" -czf "$HERE/proxypin-$VERSION-bundle.tar.gz" "proxypin-$VERSION"

build_local() {
  command -v rpmbuild >/dev/null || {
    echo "本机没有 rpmbuild，改用 docker（$FEDORA_IMAGE）" >&2
    return 1
  }
  echo "==> 本机 rpmbuild"
  rpmbuild -bb "$HERE/proxypin.spec" \
    --define "_sourcedir $HERE" \
    --define "_specdir $HERE" \
    --define "_rpmdir $OUT" \
    --define "debug_package %{nil}"
}

build_docker() {
  command -v docker >/dev/null || { echo "需要 docker 或 rpmbuild" >&2; exit 1; }
  echo "==> docker: $FEDORA_IMAGE 里 rpmbuild"
  docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$HERE:/src:ro" -v "$OUT:/out" \
    "$FEDORA_IMAGE" bash -ec '
      dnf -y -q --setopt=install_weak_deps=False install rpm-build >/dev/null
      mkdir -p /work
      cp /src/proxypin.spec /src/proxypin.desktop /src/LICENSE /src/proxypin-*-bundle.tar.gz /work/
      rpmbuild -bb /work/proxypin.spec \
        --define "_sourcedir /work" \
        --define "_rpmdir /out" \
        --define "debug_package %{nil}" >/dev/null
    '
}

mkdir -p "$OUT"
build_local || build_docker

echo
echo "==> 产物："
find "$OUT" -name '*.rpm' -newermt '-10 minutes' -print -exec ls -lh {} \;
