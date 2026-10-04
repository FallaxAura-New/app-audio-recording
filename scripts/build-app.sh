#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_NAME="NRadio 直播录音.app"
APP_DIR="$PROJECT_DIR/dist/$APP_NAME"
if [[ -n "${LAME_PREFIX:-}" ]]; then
    : # Allow an explicitly supplied installation prefix.
elif [[ -f /opt/homebrew/opt/lame/lib/libmp3lame.dylib ]]; then
    LAME_PREFIX=/opt/homebrew/opt/lame
elif [[ -f /usr/local/opt/lame/lib/libmp3lame.dylib ]]; then
    LAME_PREFIX=/usr/local/opt/lame
else
    LAME_PREFIX="$(brew --prefix lame)"
fi
if [[ ! -f "$LAME_PREFIX/lib/libmp3lame.dylib" ]]; then
    echo "请先安装 MP3 编码依赖：brew install lame" >&2
    exit 1
fi

cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/ModuleCache"
swift build --disable-sandbox -c release -debug-info-format none

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
cp ".build/release/NRadioRecorder" "$APP_DIR/Contents/MacOS/NRadioRecorder"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -f "$APP_DIR/Contents/Frameworks/libmp3lame.dylib" ]]; then
    chmod u+w "$APP_DIR/Contents/Frameworks/libmp3lame.dylib"
fi
cp -L "$LAME_PREFIX/lib/libmp3lame.dylib" "$APP_DIR/Contents/Frameworks/libmp3lame.dylib"
chmod u+w "$APP_DIR/Contents/Frameworks/libmp3lame.dylib"
cp "$LAME_PREFIX/COPYING" "$APP_DIR/Contents/Resources/LAME-COPYING"
cp "$LAME_PREFIX/LICENSE" "$APP_DIR/Contents/Resources/LAME-LICENSE"
install_name_tool -id "@rpath/libmp3lame.dylib" "$APP_DIR/Contents/Frameworks/libmp3lame.dylib"

codesign --force --deep --sign - "$APP_DIR"
echo "构建完成：$APP_DIR"
