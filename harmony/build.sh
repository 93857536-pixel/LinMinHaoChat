#!/usr/bin/env bash
# build.sh — LinMinHaoChat HarmonyOS 一键构建 .hap(macOS)
#
# 前置(一次性, 见 docs/README.md「构建 .hap」):
#   1) 登录 developer.huawei.com 下载 macOS(arm64) HarmonyOS Command Line Tools, 解压到 ~/command-line-tools
#   2) 安装/确认 JDK 17 与 node 20(hvigor 依赖)
#   3) 首次构建在 DevEco Studio 里做一次「本地自动签名」(生成调试证书 + .pb 签名 profile),
#      或自备调试/发布证书填 build-profile.json5
#
# 用法:
#   cd harmony && ./build.sh            # 出 debug hap(默认, 需签名)
#   cd harmony && ./build.sh release     # 出 release hap
# 产物: entry/build/default/outputs/default/entry-default-*.hap  (并复制到 ~/Desktop)

set -euo pipefail
MODE="${1:-debug}"
cd "$(dirname "$0")"

echo "================ LinMinHaoChat HarmonyOS 构建 ================"
echo "模式: $MODE"

# --- 定位 hvigorw / SDK ---
if [ -n "${OHOS_HOME:-}" ]; then
  export PATH="$OHOS_HOME/bin:$OHOS_HOME/toolchains:$PATH"
  echo "OHOS_HOME=$OHOS_HOME"
else
  # 常见安装位置
  for d in "$HOME/command-line-tools" "$HOME/OpenHarmony/command-line-tools"; do
    if [ -d "$d" ]; then
      export OHOS_HOME="$d"
      export PATH="$OHOS_HOME/bin:$OHOS_HOME/toolchains:$PATH"
      echo "发现 OHOS_HOME=$d"
      break
    fi
  done
fi

# 校验
if ! command -v hvigorw >/dev/null 2>&1; then
  echo "[错误] 未找到 hvigorw。请先装华为 Command Line Tools 并 export OHOS_HOME/PATH, 见 docs/README.md。"
  exit 1
fi

# 校验 JDK / node
if ! command -v java >/dev/null 2>&1; then
  echo "[警告] 未找到 java; hvigor 需要 JDK 17。"
fi

# --- 构建 ---
echo "--- clean ---"
./hvigorw clean || true
echo "--- 装依赖(ohpm) ---"
if command -v ohpm >/dev/null 2>&1; then
  ohpm install --all || echo "[警告] ohpm install 有告警, 继续构建"
else
  echo "[警告] 未找到 ohpm, 跳过 install(首次构建 DevEco 会自动装)"
fi

echo "--- assemble hap ($MODE) ---"
if [ "$MODE" = "release" ]; then
  ./hvigorw assembleHap --mode module -p product=default -p buildMode=release
else
  ./hvigorw assembleHap --mode module -p product=default -p buildMode=debug
fi

# --- 收集产物 ---
OUT_DIR="entry/build/outputs"
echo "--- 找产物 ---"
HAP=$(find "$OUT_DIR" -name "*.hap" -newer "$0" 2>/dev/null | sort | tail -1 || true)
if [ -z "${HAP:-}" ]; then
  HAP=$(find "$OUT_DIR" -name "*.hap" 2>/dev/null | sort | tail -1 || true)
fi

if [ -z "${HAP:-}" ] || [ ! -f "$HAP" ]; then
  echo "[错误] 未找到 .hap 产物。上面 hvigorw 输出若报签名错误, 见 docs/README.md「签名」一节。"
  exit 1
fi

# 复制到桌面, 文件名带版本与模式
BASE="LinMinHaoChat-harmony-1.9.16-${MODE}.hap"
cp "$HAP" "$HOME/Desktop/$BASE"
echo ""
echo "================ 构建完成 ================"
echo "hap: $HAP"
echo "桌面副本: $HOME/Desktop/$BASE"
echo "体积: $(du -h "$HAP" | cut -f1)"
echo "SHA256: $(shasum -a 256 "$HAP" | cut -d' ' -f1)"
