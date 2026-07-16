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
pluginkit -a /Applications/EasyRight.app/Contents/PlugIns/EasyRightExt.appex
pluginkit -e use -i com.diy.easyright.app.ext

echo "==> 重启 Finder 扩展进程(使新代码生效)"
pkill -x EasyRightExt 2>/dev/null || true

echo ""
echo "完成!在 Finder 里右键任意文件/文件夹即可看到菜单。"
echo "如果菜单没出现:系统设置 → 通用 → 登录项与扩展 → Finder 扩展,勾选 EasyRight。"
echo ""
echo "⚠️  重要:ad-hoc 签名重装后会失效,之前授予的「屏幕录制」「辅助功能」权限需要重新授权:"
echo "   系统设置 → 隐私与安全性 → 屏幕录制 / 辅助功能,把 EasyRight 移除(-)后重新添加勾选。"
echo "   (想避免这个麻烦:用钥匙串访问创建名为 EasyRight Dev 的自签名代码签名证书,"
echo "    以后 build.sh 会自动改用它,权限即可长期保留)"
