#!/usr/bin/env bash
# 在 macOS 上编译 RemoteDebug.dylib（需要 Xcode / Command Line Tools）
# 用法: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "没有 xcrun，请在 macOS 上运行；Windows 请用 GitHub Actions 编译"
  exit 1
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="build"
mkdir -p "$OUT"

echo "[*] SDK: $SDK"

xcrun --sdk iphoneos clang \
  -arch arm64 \
  -miphoneos-version-min=14.0 \
  -isysroot "$SDK" \
  -dynamiclib \
  -fobjc-arc \
  -O2 \
  -Wall \
  -Wno-unused-function \
  -install_name @executable_path/RemoteDebug.dylib \
  -framework Foundation \
  -framework UIKit \
  -framework JavaScriptCore \
  -framework AudioToolbox \
  -framework CoreGraphics \
  -framework CoreFoundation \
  -o "$OUT/RemoteDebug.dylib" \
  src/RemoteDebug.m src/RDIndexHTML.m src/RDHook.m \
  src/RDAutomation.m src/RDTool.m src/RDFloat.m

if command -v ldid >/dev/null 2>&1; then
  ldid -S "$OUT/RemoteDebug.dylib"
  echo "[*] 已 ldid 签名"
fi

echo "[✓] $OUT/RemoteDebug.dylib"
file "$OUT/RemoteDebug.dylib" || true
