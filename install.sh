#!/bin/bash
# 一键构建 + 安装 + 启用 Finder 扩展(修改代码后重新运行即可)
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

echo "==> 退出旧实例"
pkill -x EasyRight 2>/dev/null || true
sleep 1

echo "==> 安装到 /Applications"
rm -rf /Applications/EasyRight.app
ditto build/EasyRight.app /Applications/EasyRight.app

echo "==> 启动主应用"
open /Applications/EasyRight.app

echo "==> 注册并启用 Finder 扩展"
pluginkit -e ignore -i com.diy.easyright.app.ext 2>/dev/null || true
pluginkit -r /Applications/EasyRight.app/Contents/PlugIns/EasyRightExt.appex 2>/dev/null || true
pluginkit -a /Applications/EasyRight.app/Contents/PlugIns/EasyRightExt.appex
pluginkit -e use -i com.diy.easyright.app.ext

echo "==> 重启 Finder(使新版本 / 新签名的扩展立即生效)"
pkill -x EasyRightExt 2>/dev/null || true
killall Finder 2>/dev/null || true

echo ""
echo "完成!在 Finder 里右键任意文件/文件夹即可看到菜单。"
echo "如果菜单没出现:系统设置 → 通用 → 登录项与扩展 → Finder 扩展,勾选 EasyRight。"
echo ""
SIGNING_DETAILS=$(codesign -dv --verbose=4 /Applications/EasyRight.app 2>&1 || true)
if grep -Fq "Authority=EasyRight Dev" <<< "$SIGNING_DETAILS"; then
    echo "✅ 已使用固定自签名证书 EasyRight Dev。以后用同一证书覆盖安装时,已有 TCC 授权可保持。"
else
    echo "⚠️  当前使用 ad-hoc 签名。重新构建安装后,屏幕录制 / 辅助功能授权可能失效。"
    echo "   请在登录钥匙串中创建并信任名为 EasyRight Dev 的代码签名证书。"
fi
