#!/usr/bin/env bash
# 構建、打包並啟動 build/AirHeadMouse.app（運動權限要求必須是 .app 包）。
# 會先退出正在運行的舊版本——否則 `open` 只會把舊進程帶到前台，新代碼不會生效。
# 用法：scripts/bundle.sh [debug|release]   默認 release
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/AirHeadMouse.app"
SIGN_ID="${SIGN_IDENTITY:--}"   # 默認 ad-hoc 簽名；可設 SIGN_IDENTITY="Apple Development: ..." 避免每次重建後重新授權
BUILD_ID="$(date +%Y%m%d-%H%M%S)"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/AirHeadMouse"

# 退出舊實例
if pgrep -x AirHeadMouse >/dev/null; then
    echo "⏹  退出正在運行的 AirHeadMouse…"
    pkill -x AirHeadMouse || true
    for _ in 1 2 3 4 5 6; do
        pgrep -x AirHeadMouse >/dev/null || break
        sleep 0.5
    done
    pkill -9 -x AirHeadMouse 2>/dev/null || true
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AirHeadMouse"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_ID" "$APP/Contents/Info.plist"

codesign --force --deep --sign "$SIGN_ID" "$APP"
open "$APP"
echo "✅ 已啟動構建 $BUILD_ID（菜單底部應顯示同一構建號）"
