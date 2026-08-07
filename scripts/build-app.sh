#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_NAME="NRadio 直播录音.app"
APP_DIR="$PROJECT_DIR/dist/$APP_NAME"

cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/ModuleCache"
swift build --disable-sandbox -c release -debug-info-format none

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp ".build/release/NRadioRecorder" "$APP_DIR/Contents/MacOS/NRadioRecorder"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

codesign --force --deep --sign - "$APP_DIR"
echo "构建完成：$APP_DIR"
