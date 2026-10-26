#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

VOLUME_NAME="WoodDeck"
APP_NAME="WoodDeck.app"
DIST_DIR="dist"
WORK_DIR=".agents/build-dmg"
STAGE_DIR="$WORK_DIR/stage"
MOUNT_DIR="$(pwd)/$WORK_DIR/mnt"
RW_DMG="$WORK_DIR/$VOLUME_NAME-rw.dmg"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
FINAL_DMG="$DIST_DIR/$VOLUME_NAME-$VERSION.dmg"

MOUNTPOINT=""

detach_volume() {
	if [ -n "$MOUNTPOINT" ] && [ -d "$MOUNTPOINT" ]; then
		hdiutil detach "$MOUNTPOINT" -force >/dev/null 2>&1 || true
	fi
}
trap detach_volume EXIT

./Scripts/build-app.sh

if [ ! -f "$APP_NAME/Contents/Info.plist" ]; then
	echo "未找到 $APP_NAME/Contents/Info.plist" >&2
	exit 1
fi

mkdir -p "$DIST_DIR"
rm -rf "$WORK_DIR"
mkdir -p "$STAGE_DIR" "$MOUNT_DIR"

ditto "$APP_NAME" "$STAGE_DIR/$APP_NAME"
ln -s /Applications "$STAGE_DIR/Applications"

echo "创建中间镜像（可读写）"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGE_DIR" -fs HFS+ -format UDRW -ov "$RW_DMG" >/dev/null

hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen -mountpoint "$MOUNT_DIR" >/dev/null
MOUNTPOINT="$MOUNT_DIR"

if ! hdiutil info | grep -qF "$MOUNTPOINT"; then
	echo "挂载可写镜像失败" >&2
	exit 1
fi
echo "可写镜像挂载于 $MOUNTPOINT"

if osascript <<APPLESCRIPT
tell application "Finder"
	set volumeFolder to POSIX file "$MOUNTPOINT" as alias
	open volumeFolder
	set volumeWindow to container window of volumeFolder
	set current view of volumeWindow to icon view
	set toolbar visible of volumeWindow to false
	set statusbar visible of volumeWindow to false
	set bounds of volumeWindow to {200, 200, 800, 560}
	set viewOptions to icon view options of volumeWindow
	set arrangement of viewOptions to not arranged
	set icon size of viewOptions to 128
	set position of item "$APP_NAME" of volumeFolder to {170, 240}
	set position of item "Applications" of volumeFolder to {450, 240}
	update volumeFolder without registering applications
	delay 1
	close volumeWindow
end tell
APPLESCRIPT
then
	if [ -f "$MOUNTPOINT/.DS_Store" ]; then
		echo "已通过 Finder 设置图标大小与位置"
	else
		echo "Finder 未写入 .DS_Store，DMG 使用纯文件布局"
	fi
else
	echo "Finder 自动化不可用，改用纯文件布局，DMG 内不包含 .DS_Store"
fi

# 卷图标放在 Finder 调整视图之后再写，避免被 Finder 重写卷属性时清掉
if [ -f Resources/AppIcon.icns ]; then
	cp Resources/AppIcon.icns "$MOUNT_DIR/.VolumeIcon.icns"
	SetFile -a C "$MOUNT_DIR"
fi

sync
if ! hdiutil detach "$MOUNTPOINT" >/dev/null; then
	echo "卸载失败，等待 2 秒后重试" >&2
	sleep 2
	hdiutil detach "$MOUNTPOINT" >/dev/null
fi
MOUNTPOINT=""

rm -f "$FINAL_DMG"
echo "压缩为 UDZO"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL_DMG" >/dev/null

rm -rf "$WORK_DIR"

SIZE_HUMAN="$(ls -lh "$FINAL_DMG" | awk '{print $5}')"
SIZE_BYTES="$(stat -f%z "$FINAL_DMG")"
echo "DMG 路径：$(pwd)/$FINAL_DMG"
echo "DMG 大小：${SIZE_HUMAN}（${SIZE_BYTES} 字节）"
