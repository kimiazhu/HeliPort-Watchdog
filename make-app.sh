#!/bin/bash
#
# make-app.sh —— 组装 HeliPortWatchdog.app
#
# 1. swift build -c release --product HeliPortWatchdog
# 2. 组装 dist/HeliPortWatchdog.app（Info.plist：LSUIElement 纯托盘、AppIcon 图标等）
# 3. ad-hoc codesign
#
# 注意：SMAppService 登录项只认 bundle；.app 移动位置会使已注册的登录项失效，
#       请放在固定位置运行（详见 README）。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="HeliPortWatchdog"
BUNDLE_ID="com.iassistpro.heliport-watchdog"
DIST="dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"

echo "==> swift build -c release --product $APP_NAME"
swift build -c release --product "$APP_NAME"

BIN=".build/release/$APP_NAME"
if [ ! -f "$BIN" ]; then
    echo "错误：未找到编译产物 $BIN" >&2
    exit 1
fi

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>HeliPortWatchdog 需要向 System Events 发送 Apple Events，以操作 HeliPort 菜单中的 Wi-Fi 开关。</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

cp "$BIN" "$CONTENTS/MacOS/$APP_NAME"

ICON="Resources/AppIcon.icns"
if [ -f "$ICON" ]; then
    cp "$ICON" "$CONTENTS/Resources/AppIcon.icns"
else
    echo "警告：未找到 $ICON（可用 swift Scripts/gen-icon.swift <临时目录> + iconutil 生成）" >&2
fi

echo "==> ad-hoc codesign"
codesign --force --sign - "$APP"

echo "打包完成: $APP"
echo "运行: open \"$APP\""
