#!/bin/bash
#
# build-app.sh — 把 SPM 可执行文件打包成可双击运行的 WiFiDoctor.app
#
# 用法：
#   ./build-app.sh            # release 构建 + 打包 + ad-hoc 签名
#   ./build-app.sh debug      # debug 构建
#
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="release"
[ "${1:-}" = "debug" ] && CONFIG="debug"

APP="build/WiFiDoctor.app"
BUNDLE_ID="com.maynard.wifidoctor"
VERSION="0.1.0"

echo "==> 编译 ($CONFIG)"
swift build -c "$CONFIG" --product WiFiDoctor

BIN="$(swift build -c "$CONFIG" --product WiFiDoctor --show-bin-path)/WiFiDoctor"
[ -f "$BIN" ] || { echo "找不到二进制: $BIN"; exit 1; }

echo "==> 组装 .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WiFiDoctor"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>WiFiDoctor</string>
    <key>CFBundleDisplayName</key>           <string>网络体检</string>
    <key>CFBundleExecutable</key>            <string>WiFiDoctor</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
    <key>CFBundleVersion</key>               <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>       <string>14.0</string>

    <!-- 只在菜单栏显示，不进 Dock -->
    <key>LSUIElement</key>                   <true/>

    <!-- CoreWLAN 读取 RSSI 需要定位权限 -->
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>用于读取 Wi-Fi 信号强度与信道，以显示网络质量。</string>

    <!-- 中文界面 -->
    <key>CFBundleDevelopmentRegion</key>    <string>zh_CN</string>
</dict>
</plist>
PLIST

echo "==> 签名（ad-hoc，仅本机可运行）"
codesign --force --deep --sign - "$APP" 2>&1 | sed 's/^/    /'

echo "==> 完成"
echo "    $APP"
echo "    运行: open $APP"