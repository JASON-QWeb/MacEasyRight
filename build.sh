#!/bin/bash
# EasyRight 构建脚本:编译主应用 + Finder 扩展,组装 .app 并签名
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
    -framework AppKit -framework SwiftUI -framework FinderSync \
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

# 默认使用 ad-hoc 签名。本机若有固定代码签名证书，可通过环境变量显式传入：
# CODESIGN_IDENTITY="证书名称" ./build.sh
IDENTITY="${CODESIGN_IDENTITY:--}"
if [ "$IDENTITY" != "-" ]; then
    CODE_SIGNING_IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
    if ! grep -Fq "\"$IDENTITY\"" <<< "$CODE_SIGNING_IDENTITIES"; then
        echo "错误:找不到可用的代码签名身份: $IDENTITY"
        exit 1
    fi
fi
echo "==> 签名(identity: $IDENTITY)"
codesign --force --sign "$IDENTITY" --entitlements Resources/ext.entitlements "$APPEX"
codesign --force --sign "$IDENTITY" "$APP"

echo "==> 完成:$APP"
