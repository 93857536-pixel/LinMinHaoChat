#!/bin/bash
# 打出结构正确的未签名 IPA(供全能签/ESign 等侧载工具使用)
#
# ⚠️ 背景(2026-10-06 踩坑): 早期脚本写成
#     zip -ry out.ipa /tmp/vNzip/Payload
#   zip 会把**绝对路径**原样记进归档 → 包内变成 `tmp/vNzip/Payload/...`,
#   而不是标准的 `Payload/...`。v8–v19 的包全部中招,严格的签名工具会解析失败。
#   正确做法:**先 cd 进暂存目录,再用相对路径 zip**。脚本里已用 `pushd` 保证。
#
# 用法: ./pack-ipa.sh <xcarchive路径> [输出ipa路径]
set -euo pipefail

ARCHIVE="${1:?用法: pack-ipa.sh <LinMinHaoChat-archive-vN.xcarchive> [out.ipa]}"
OUT="${2:-$HOME/Desktop/LinMinHaoChat-unsigned-$(basename "$ARCHIVE" .xcarchive | sed 's/.*-archive-//').ipa}"
APP="$ARCHIVE/Products/Applications/LinMinHaoChat.app"
[ -d "$APP" ] || { echo "找不到 .app: $APP" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"

# 关键: cd 到暂存目录后用**相对路径**打包(否则包内会多一层 tmp/... 前缀)
rm -f "$OUT"
( cd "$STAGE" && zip -ry "$OUT" Payload -q )

# --- 自检:布局 / 版本 / 可执行权限 ---
TOP=$(unzip -l "$OUT" | awk 'NR==4{print $4}')
[ "$TOP" = "Payload/" ] || { echo "❌ 布局错误: 顶层是 '$TOP',应为 'Payload/'" >&2; exit 1; }
CHK=$(mktemp -d); trap 'rm -rf "$STAGE" "$CHK"' EXIT
unzip -o -q "$OUT" -d "$CHK"
VER=$(plutil -extract CFBundleShortVersionString raw "$CHK/Payload/LinMinHaoChat.app/Info.plist")
BUILD=$(plutil -extract CFBundleVersion raw "$CHK/Payload/LinMinHaoChat.app/Info.plist")
BID=$(plutil -extract CFBundleIdentifier raw "$CHK/Payload/LinMinHaoChat.app/Info.plist")
PERM=$(stat -f '%Sp' "$CHK/Payload/LinMinHaoChat.app/LinMinHaoChat")
case "$PERM" in *x*) ;; *) echo "❌ 可执行位丢失: $PERM" >&2; exit 1;; esac

echo "✅ $OUT"
echo "   布局 $TOP | 版本 $VER build $BUILD | $BID | 主程序 $PERM"
echo "   $(du -h "$OUT" | cut -f1)  $(shasum -a 256 "$OUT" | cut -c1-64)"
