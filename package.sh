#!/bin/bash
# 构建并制作个人分发 DMG，默认使用 ad-hoc 签名。
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${CODESIGN_IDENTITY:--}"

if [ "$IDENTITY" != "-" ]; then
    CODE_SIGNING_IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
    if ! grep -Fq "\"$IDENTITY\"" <<< "$CODE_SIGNING_IDENTITIES"; then
        echo "错误:钥匙串中没有可用的代码签名身份: $IDENTITY"
        exit 1
    fi
fi

CODESIGN_IDENTITY="$IDENTITY" ./build.sh

SIGNING_DETAILS=$(codesign -dv --verbose=4 build/EasyRight.app 2>&1 || true)
if [ "$IDENTITY" = "-" ]; then
    if ! grep -Fq "Signature=adhoc" <<< "$SIGNING_DETAILS"; then
        echo "错误:应用没有使用 ad-hoc 签名,停止打包。"
        exit 1
    fi
elif ! grep -Fq "Authority=$IDENTITY" <<< "$SIGNING_DETAILS"; then
    echo "错误:应用没有使用 $IDENTITY 签名,停止打包。"
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/App-Info.plist)
ARCH=$(uname -m)
DIST_DIR="$PWD/dist"
DMG_PATH="$DIST_DIR/EasyRight-$VERSION-$ARCH.dmg"
RW_DMG_PATH="$DIST_DIR/.EasyRight-$VERSION-$ARCH.rw.dmg"
VOLUME_NAME="EasyRight $VERSION"
# 使用唯一的临时卷名设置 Finder 布局，避免用户已挂载同版本 DMG 时
# AppleScript 误把 .DS_Store 写到旧卷。布局完成后再改回对外展示的正式卷名。
PACKAGING_VOLUME_NAME="EasyRight Packaging $$"
RENDER_DIR=$(mktemp -d "${TMPDIR:-/tmp}/easyright-background.XXXXXX")
MOUNT_DIR=""
MOUNT_DEVICE=""

detach_image() {
    local device=$1
    if hdiutil detach "$device" >/dev/null 2>&1; then return 0; fi
    echo "==> 临时 DMG 被 Finder 扩展占用，改用强制卸载"
    hdiutil detach -force "$device" >/dev/null
}

cleanup() {
    if [ -n "$MOUNT_DEVICE" ]; then
        detach_image "$MOUNT_DEVICE" >/dev/null 2>&1 || true
    fi
    find "$RENDER_DIR" -mindepth 1 -delete >/dev/null 2>&1 || true
    rmdir "$RENDER_DIR" >/dev/null 2>&1 || true
    if [ -e "$RW_DMG_PATH" ]; then rm "$RW_DMG_PATH"; fi
}
trap cleanup EXIT

mkdir -p "$DIST_DIR"
if [ -e "$DMG_PATH" ]; then rm "$DMG_PATH"; fi
if [ -e "$RW_DMG_PATH" ]; then rm "$RW_DMG_PATH"; fi

echo "==> 渲染 DMG 安装背景"
BACKGROUND_PNG="$RENDER_DIR/background.png"
sips -s format png Resources/DMGBackground.svg --out "$BACKGROUND_PNG" >/dev/null
if [ ! -f "$BACKGROUND_PNG" ]; then
    echo "错误:无法生成 DMG 背景图。"
    exit 1
fi

echo "==> 创建可写 DMG"
APP_SIZE_KB=$(du -sk build/EasyRight.app | awk '{print $1}')
DMG_SIZE_MB=$((APP_SIZE_KB * 2 / 1024 + 16))
if [ "$DMG_SIZE_MB" -lt 32 ]; then DMG_SIZE_MB=32; fi
hdiutil create \
    -size "${DMG_SIZE_MB}m" \
    -fs HFS+ \
    -volname "$PACKAGING_VOLUME_NAME" \
    -ov \
    "$RW_DMG_PATH" >/dev/null

ATTACH_OUTPUT=$(hdiutil attach "$RW_DMG_PATH" -readwrite -noverify -noautoopen)
MOUNT_DEVICE=$(awk '/Apple_HFS|Apple_APFS/ {print $1; exit}' <<< "$ATTACH_OUTPUT")
MOUNT_DIR=$(awk '/Apple_HFS|Apple_APFS/ {print substr($0, index($0, "/Volumes/")); exit}' <<< "$ATTACH_OUTPUT")
if [ -z "$MOUNT_DEVICE" ] || [ -z "$MOUNT_DIR" ]; then
    echo "错误:无法挂载可写 DMG。"
    exit 1
fi

ditto build/EasyRight.app "$MOUNT_DIR/EasyRight.app"
ln -s /Applications "$MOUNT_DIR/Applications"
mkdir -p "$MOUNT_DIR/.background"
ditto "$BACKGROUND_PNG" "$MOUNT_DIR/.background/background.png"

echo "==> 设置拖拽安装窗口布局"
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$PACKAGING_VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        set bounds of container window to {100, 100, 740, 500}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 14
        set background picture of viewOptions to file ".background:background.png"
        set position of item "EasyRight.app" of container window to {170, 220}
        set position of item "Applications" of container window to {470, 220}
        close
    end tell
end tell
delay 2
APPLESCRIPT

sync
if [ ! -f "$MOUNT_DIR/.DS_Store" ]; then
    echo "错误:Finder 未写入 DMG 窗口布局(.DS_Store)。"
    exit 1
fi
diskutil rename "$MOUNT_DEVICE" "$VOLUME_NAME" >/dev/null
sync
detach_image "$MOUNT_DEVICE"
MOUNT_DEVICE=""

echo "==> 压缩并签名 DMG"
hdiutil convert "$RW_DMG_PATH" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH" >/dev/null

codesign --force --sign "$IDENTITY" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"
hdiutil verify "$DMG_PATH"

echo ""
echo "打包完成:$DMG_PATH"
shasum -a 256 "$DMG_PATH"
