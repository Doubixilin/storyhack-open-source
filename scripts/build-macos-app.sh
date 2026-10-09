#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
CONFIGURATION=${1:-debug}

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
  print -u2 "用法：$0 [debug|release]"
  exit 2
fi

BUILD_ROOT="$PROJECT_ROOT/.build"
APP_BUNDLE="$BUILD_ROOT/StoryhackCommunity.app"
mkdir -p "$BUILD_ROOT"
STAGING_BUNDLE=$(mktemp -d "$BUILD_ROOT/StoryhackCommunity.app.staging.XXXXXX")

cleanup() {
  if [[ -d "$STAGING_BUNDLE" ]]; then
    rm -rf -- "$STAGING_BUNDLE"
  fi
}
trap cleanup EXIT

export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/swiftpm-module-cache"

cd "$PROJECT_ROOT"
swift build --disable-sandbox -c "$CONFIGURATION" --product WorldbookMac
BIN_DIRECTORY=$(swift build --disable-sandbox -c "$CONFIGURATION" --show-bin-path)

mkdir -p "$STAGING_BUNDLE/Contents/MacOS" "$STAGING_BUNDLE/Contents/Resources"
cp "$PROJECT_ROOT/Apps/macOS/Resources/Info.plist" "$STAGING_BUNDLE/Contents/Info.plist"
cp "$PROJECT_ROOT/Apps/macOS/Resources/AppIcon.icns" "$STAGING_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$BIN_DIRECTORY/WorldbookMac" "$STAGING_BUNDLE/Contents/MacOS/WorldbookMac"

cp "$PROJECT_ROOT/Apps/macOS/Resources/PrivacyInfo.xcprivacy" "$STAGING_BUNDLE/Contents/Resources/"
cp "$PROJECT_ROOT/LICENSE" "$PROJECT_ROOT/THIRD_PARTY_NOTICES.md" "$STAGING_BUNDLE/Contents/Resources/"
for RESOURCE_BUNDLE in "$BIN_DIRECTORY/"*.bundle(N); do
  cp -R "$RESOURCE_BUNDLE" "$STAGING_BUNDLE/Contents/Resources/"
done
test -d "$STAGING_BUNDLE/Contents/Resources/WorldbookApp_StoryMaterialKit.bundle"
"$STAGING_BUNDLE/Contents/MacOS/WorldbookMac" --verify-resources

plutil -lint "$STAGING_BUNDLE/Contents/Info.plist"
codesign --force --sign - "$STAGING_BUNDLE"

case "$APP_BUNDLE" in
  "$PROJECT_ROOT/.build/"*.app) ;;
  *)
    print -u2 "拒绝替换非构建目录中的 App：$APP_BUNDLE"
    exit 3
    ;;
esac

rm -rf -- "$APP_BUNDLE"
mv "$STAGING_BUNDLE" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

print "$APP_BUNDLE"
