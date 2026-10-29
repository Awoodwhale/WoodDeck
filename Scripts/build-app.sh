#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIGURATION="${1:-release}"
APP="WoodDeck.app"

swift build -c "$CONFIGURATION"
BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/WoodDeck"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/WoodDeck"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/MediaRemoteAdapter "$APP/Contents/Resources/MediaRemoteAdapter"
chmod +x "$APP/Contents/Resources/MediaRemoteAdapter/mediaremote-adapter.pl"
# DSH 插件源码：打开 DSH 会话读取时写进各个 profile
cp -R Resources/dsh-plugin "$APP/Contents/Resources/dsh-plugin"
codesign --force --deep --sign - "$APP"
echo "已生成 $(pwd)/$APP"
