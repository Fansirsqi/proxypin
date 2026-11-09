#!/bin/bash
# CI/容器里构建 Arch 包用的入口（GitHub Actions 的 arch 任务调用它）。
#
# 等价于：
#   cd packaging/arch && PROXYPIN_SRC=<repo> PATH=/opt/flutter/bin:$PATH makepkg -f --nodeps --nocheck
#
# 单独一个脚本是为了把 PATH / 参数 / 报错信息固定在 CI 里，本地也能直接复现：
#   PROXYPIN_SRC=$PWD /path/to/flutter/bin/flutter --version   # 先确认 SDK 可用
#   PATH=/opt/flutter/bin:$PATH ./packaging/arch/makepkg-ci.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

: "${PROXYPIN_SRC:=$(cd ../.. && pwd)}"

flutter_bin=${FLUTTER_BIN:-}
if [[ -z $flutter_bin ]]; then
  for candidate in /opt/flutter/bin/flutter "$HOME/flutter/bin/flutter"; do
    [[ -x $candidate ]] && flutter_bin=$candidate && break
  done
fi
if [[ -z $flutter_bin ]]; then
  flutter_bin=$(command -v flutter || true)
fi
[[ -n $flutter_bin ]] || { echo "flutter SDK not found (set FLUTTER_BIN or install to /opt/flutter)" >&2; exit 1; }

echo "==> flutter: $flutter_bin"
echo "==> source : $PROXYPIN_SRC"
PATH="$(dirname "$flutter_bin"):$PATH" PROXYPIN_SRC="$PROXYPIN_SRC" \
  makepkg -f --nodeps --nocheck
