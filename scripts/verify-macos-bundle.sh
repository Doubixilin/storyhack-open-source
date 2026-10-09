#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
APP_BUNDLE=${1:-"$PROJECT_ROOT/.build/StoryhackCommunity.app"}
test -d "$APP_BUNDLE"
PROBE_ROOT=$(mktemp -d)
trap 'rm -rf -- "$PROBE_ROOT"' EXIT
cp -R "$APP_BUNDLE" "$PROBE_ROOT/StoryhackCommunity.app"
codesign --verify --deep --strict --verbose=2 "$PROBE_ROOT/StoryhackCommunity.app"
# 禁止读取原构建目录，证明搬移后的 App 不依赖 SwiftPM 的开发路径。
sandbox-exec -p "(version 1)(allow default)(deny file-read* (subpath \"$PROJECT_ROOT/.build\"))" \
  "$PROBE_ROOT/StoryhackCommunity.app/Contents/MacOS/WorldbookMac" --verify-resources
print "Moved macOS bundle verified"
