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
APP_BINARY="$APP/Contents/MacOS/EasyRight"
EXT_BINARY="$APPEX/Contents/MacOS/EasyRightExt"
APP_STAMP="$BUILD/.app-source-fingerprint"
EXT_STAMP="$BUILD/.extension-source-fingerprint"
APP_SOURCES=(Sources/Shared/*.swift Sources/App/*.swift)
EXT_SOURCES=(Sources/Shared/*.swift Sources/Extension/*.swift)

if [ "${1:-}" = "clean" ]; then
    echo "==> 清理构建产物"
    rm -rf "$BUILD"
fi

source_fingerprint() {
    local target_name=$1
    shift
    {
        printf '%s\n' "$target_name" "$TARGET" "$SDK"
        swiftc --version 2>&1
        for input in "$@"; do
            printf '%s\n' "$input"
            shasum -a 256 "$input"
        done
    } | shasum -a 256 | awk '{print $1}'
}

needs_rebuild() {
    local output=$1
    local stamp=$2
    local expected=$3
    [ ! -f "$output" ] || [ ! -f "$stamp" ] || [ "$(<"$stamp")" != "$expected" ]
}

echo "==> 创建 bundle 结构"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"

APP_FINGERPRINT=$(source_fingerprint "EasyRight app -O v1" "${APP_SOURCES[@]}" build.sh)
EXT_FINGERPRINT=$(source_fingerprint "EasyRight extension -O v1" "${EXT_SOURCES[@]}" build.sh)

if needs_rebuild "$APP_BINARY" "$APP_STAMP" "$APP_FINGERPRINT"; then
    echo "==> 编译主应用 EasyRight"
    swiftc -O \
        -module-name EasyRight \
        -target "$TARGET" -sdk "$SDK" \
        "${APP_SOURCES[@]}" \
        -framework AppKit -framework SwiftUI -framework FinderSync \
        -o "$APP_BINARY"
    printf '%s\n' "$APP_FINGERPRINT" > "$APP_STAMP"
else
    echo "==> 主应用源码未变化，跳过编译"
fi

if needs_rebuild "$EXT_BINARY" "$EXT_STAMP" "$EXT_FINGERPRINT"; then
    echo "==> 编译 Finder 扩展 EasyRightExt"
    swiftc -O \
        -module-name EasyRightExt \
        -parse-as-library \
        -application-extension \
        -target "$TARGET" -sdk "$SDK" \
        "${EXT_SOURCES[@]}" \
        -framework AppKit -framework Foundation -framework FinderSync \
        -Xlinker -e -Xlinker _NSExtensionMain \
        -o "$EXT_BINARY"
    printf '%s\n' "$EXT_FINGERPRINT" > "$EXT_STAMP"
else
    echo "==> Finder 扩展源码未变化，跳过编译"
fi

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
