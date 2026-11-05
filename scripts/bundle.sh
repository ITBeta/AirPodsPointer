#!/usr/bin/env bash
# 構建並打包成 build/AirHeadMouse.app（運動權限要求必須是 .app 包）。
# 用法：scripts/bundle.sh [debug|release]   默認 release
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/AirHeadMouse.app"
SIGN_ID="${SIGN_IDENTITY:--}"   # 默認 ad-hoc 簽名；可設 SIGN_IDENTITY="Apple Development: ..." 避免每次重建後重新授權

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/AirHeadMouse"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AirHeadMouse"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --deep --sign "$SIGN_ID" "$APP"
echo "✅ 已生成 $APP"
echo "   運行：open $APP"
