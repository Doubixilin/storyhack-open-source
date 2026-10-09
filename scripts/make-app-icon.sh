#!/bin/zsh
# 从 Logo 方形源稿生成 macOS AppIcon.icns 并装入 Apps/macOS/Resources/。
# 用法：scripts/make-app-icon.sh [源PNG]（缺省取 v3 B“书中生岔”的满幅方形版）
# 依赖 macOS 自带工具：sips + iconutil。

set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
SOURCE=${1:-"$PROJECT_ROOT/Assets/logo/v3/B-icon-square.png"}
ICONSET_DIR=$(mktemp -d /tmp/WorldbookAppIcon.XXXXXX)/AppIcon.iconset
DEST_DIR="$PROJECT_ROOT/Apps/macOS/Resources"

mkdir -p "$ICONSET_DIR"

# iconset 约定：icon_WxH.png 与 icon_WxH@2x.png
typeset -a SPECS=(
  "icon_16x16.png 16"
  "icon_16x16@2x.png 32"
  "icon_32x32.png 32"
  "icon_32x32@2x.png 64"
  "icon_128x128.png 128"
  "icon_128x128@2x.png 256"
  "icon_256x256.png 256"
  "icon_256x256@2x.png 512"
  "icon_512x512.png 512"
  "icon_512x512@2x.png 1024"
)

for spec in "${SPECS[@]}"; do
  name=${spec%% *}
  size=${spec##* }
  sips -z "$size" "$size" "$SOURCE" --out "$ICONSET_DIR/$name" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" --output "$DEST_DIR/AppIcon.icns"
rm -rf "${ICONSET_DIR:h}"

print "$DEST_DIR/AppIcon.icns"
