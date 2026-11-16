#!/bin/bash
# ============================================================
# 车钥匙 · 未签名 .ipa 一键构建（供 TrollStore / 巨魔安装）
#
# 用法（在 macOS 上，需已安装 Xcode）：
#   cd CarKey-iOS && bash build.sh
#
# 产出：CarKey-unsigned.ipa（Payload/CarKey.app 结构，无需任何证书）
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"

PROJECT="CarKey.xcodeproj"
SCHEME="CarKey"
APPNAME="CarKey.app"
CONFIG="Release"
DD="build"
OUT="CarKey-unsigned.ipa"

echo "==> [1/5] 检查环境"
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "✗ 未找到 xcodebuild。此脚本只能在 macOS + Xcode 上运行。"
  echo "  没有 Mac 的话，请用本工程自带的 GitHub Actions 流程（见 README）。"
  exit 1
fi
xcodebuild -version
echo ""

echo "==> [2/5] 清理旧产物"
rm -rf "$DD" Payload "$OUT"

echo "==> [3/5] 编译（CODE_SIGNING_ALLOWED=NO，不签名）"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -sdk iphoneos \
  -derivedDataPath "$DD" \
  -destination "generic/platform=iOS" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  clean build

APP=$(find "$DD" -type d -name "$APPNAME" -print -quit)
if [ -z "$APP" ]; then
  echo "✗ 未找到编译产物 $APPNAME，请检查上面的 xcodebuild 日志"
  exit 1
fi
echo "    产物: $APP"

echo "==> [4/5] 组装 Payload + ad-hoc 签名"
mkdir -p Payload
cp -R "$APP" Payload/
rm -rf "Payload/$APPNAME/_CodeSignature" 2>/dev/null || true
find Payload -name '.DS_Store' -delete 2>/dev/null || true
chmod +x "Payload/$APPNAME/$SCHEME" 2>/dev/null || true

# 关键：TrollStore 依赖 CoreTrust 做永久签名，但 .ipa 内的 .app 需要先有一层
# ad-hoc 签名（codesign -s -，纯本地、无需任何开发者证书）。
# 不做这一步，部分 iOS 版本导入 .ipa 会失败或安装后闪退。
ENT="CarKey/CarKey.entitlements"
if codesign -f -s - --deep \
     --entitlements "$ENT" \
     --identifier "com.carkey.ios.key" \
     "Payload/$APPNAME" 2>/dev/null; then
  echo "    ad-hoc 签名完成（含 entitlements）"
else
  echo "    ⚠ ad-hoc 签名跳过，尝试不带 entitlements 重试"
  codesign -f -s - --deep --identifier "com.carkey.ios.key" \
     "Payload/$APPNAME" || echo "    ⚠ 签名失败，仍会打包（TrollStore 多数情况下可自行处理）"
fi
# 自检签名是否写入
codesign -dv "Payload/$APPNAME" 2>&1 | head -3 || true
echo ""

echo "==> [5/5] 打包 .ipa"
zip -qry "$OUT" Payload -x '*.DS_Store' '*.pbxuser' '*.mode1v3'

echo ""
echo "✓ 完成：$(pwd)/$OUT"
ls -lh "$OUT"
echo ""
echo "下一步：把 $OUT 传到 iPhone（隔空投送 / 文件 App / 数据线），"
echo "        用 TrollStore 打开即可安装，无需证书、无需越狱。"
