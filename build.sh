#!/bin/bash
# EasyRight 构建脚本:编译主应用 + Finder 扩展,组装 .app 并 ad-hoc 签名
set -euo pipefail
cd "$(dirname "$0")"

ARCH=$(uname -m)
TARGET="$ARCH-apple-macos13.0"
SDK=$(xcrun --show-sdk-path)
BUILD=build
APP="$BUILD/EasyRight.app"
APPEX="$APP/Contents/PlugIns/EasyRightExt.appex"

echo "==> 清理并创建 bundle 结构"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"

echo "==> 编译主应用 EasyRight"
swiftc -O \
    -module-name EasyRight \
    -target "$TARGET" -sdk "$SDK" \
    Sources/Shared/*.swift Sources/App/*.swift \
    -framework AppKit -framework SwiftUI \
    -o "$APP/Contents/MacOS/EasyRight"

echo "==> 编译 Finder 扩展 EasyRightExt"
swiftc -O \
    -module-name EasyRightExt \
    -parse-as-library \
    -application-extension \
    -target "$TARGET" -sdk "$SDK" \
    Sources/Shared/*.swift Sources/Extension/*.swift \
    -framework AppKit -framework Foundation -framework FinderSync \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$APPEX/Contents/MacOS/EasyRightExt"

echo "==> 拷贝 Info.plist"
cp Resources/App-Info.plist "$APP/Contents/Info.plist"
cp Resources/Ext-Info.plist "$APPEX/Contents/Info.plist"
cp Resources/EasyRight.icns "$APP/Contents/Resources/EasyRight.icns"

# 有名为 "EasyRight Dev" 的自签名证书就用它(签名身份稳定,重装后 TCC 权限不失效);
# 没有则退回 ad-hoc(每次重装后需要在系统设置里重新授权屏幕录制/辅助功能)
IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "EasyRight Dev"; then
    IDENTITY="EasyRight Dev"
fi
echo "==> 签名(identity: $IDENTITY)"
codesign --force --sign "$IDENTITY" --entitlements Resources/ext.entitlements "$APPEX"
codesign --force --sign "$IDENTITY" "$APP"

echo "==> 完成:$APP"
