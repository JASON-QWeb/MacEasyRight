#!/bin/bash
# 构建固定自签名版本并制作个人分发 DMG。
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="EasyRight Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

CODE_SIGNING_IDENTITIES=$(security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null || true)
if ! grep -Fq "\"$IDENTITY\"" <<< "$CODE_SIGNING_IDENTITIES"; then
    echo "错误:登录钥匙串中没有可用的 $IDENTITY 代码签名身份。"
    echo "请先创建并信任该证书,且务必保留同一份私钥用于后续版本。"
    exit 1
fi

./build.sh

SIGNING_DETAILS=$(codesign -dv --verbose=4 build/EasyRight.app 2>&1 || true)
if ! grep -Fq "Authority=$IDENTITY" <<< "$SIGNING_DETAILS"; then
    echo "错误:应用没有使用 $IDENTITY 签名,停止打包。"
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/App-Info.plist)
ARCH=$(uname -m)
DIST_DIR="$PWD/dist"
DMG_PATH="$DIST_DIR/EasyRight-$VERSION-$ARCH.dmg"
STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/easyright-dmg.XXXXXX")
trap 'rm -rf "$STAGING_DIR"' EXIT

mkdir -p "$DIST_DIR"
if [ -e "$DMG_PATH" ]; then rm "$DMG_PATH"; fi

ditto build/EasyRight.app "$STAGING_DIR/EasyRight.app"
ln -s /Applications "$STAGING_DIR/Applications"
cp "Distribution/安装说明.txt" "$STAGING_DIR/安装说明.txt"
security find-certificate -c "$IDENTITY" -p "$KEYCHAIN" \
    | openssl x509 -outform der -out "$STAGING_DIR/EasyRight Dev.cer"

hdiutil create \
    -volname "EasyRight $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

codesign --force --sign "$IDENTITY" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"
hdiutil verify "$DMG_PATH"

echo ""
echo "打包完成:$DMG_PATH"
shasum -a 256 "$DMG_PATH"
