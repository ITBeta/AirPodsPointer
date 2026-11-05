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
VERSION="$(cat VERSION 2>/dev/null || echo unknown)"

# 檢查源碼目錄是否乾淨：MANIFEST 列出的文件必須齊全，Sources/ 下不能有多餘的 .swift 文件。
if [[ -f MANIFEST ]]; then
    bad=0
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if [[ ! -f "$f" ]]; then echo "❌ 缺少文件：$f"; bad=1; fi
    done < MANIFEST
    while IFS= read -r f; do
        if ! grep -qxF "$f" MANIFEST; then echo "❌ 多餘文件（不屬於版本 $VERSION）：$f"; bad=1; fi
    done < <(find Sources Tests -name '*.swift' | sort)
    if [[ $bad -ne 0 ]]; then
        echo
        echo "源碼目錄混入了其他版本的文件。請刪除整個目錄，重新解壓壓縮包到一個空目錄再構建。"
        exit 1
    fi
else
    echo "⚠️  沒有 MANIFEST，跳過源碼完整性檢查"
fi

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
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

codesign --force --deep --sign "$SIGN_ID" "$APP"
open "$APP"
echo "✅ 已啟動 源碼版本 $VERSION · 構建 $BUILD_ID（菜單底部應顯示相同的版本與構建號）"
