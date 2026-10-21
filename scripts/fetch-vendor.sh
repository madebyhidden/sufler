#!/bin/bash
# Скачивает готовые движки, нужные для сборки версии для Mac:
#   Vendor/whisper.xcframework — распознавание речи (whisper.cpp)
#   Vendor/llama-bin           — llama-server для языковых моделей (llama.cpp)
set -euo pipefail
cd "$(dirname "$0")/.."
WHISPER="${WHISPER:-v1.9.2}"
LLAMA="${LLAMA:-b11558}"
mkdir -p Vendor
if [ ! -d Vendor/whisper.xcframework ]; then
  curl -fL "https://github.com/ggml-org/whisper.cpp/releases/download/$WHISPER/whisper-$WHISPER-xcframework.zip" -o /tmp/whisper-xcf.zip
  unzip -q /tmp/whisper-xcf.zip -d /tmp/whisper-xcf
  mv "$(find /tmp/whisper-xcf -name whisper.xcframework -type d | head -1)" Vendor/
fi
if [ ! -x Vendor/llama-bin/llama-server ]; then
  curl -fL "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA/llama-$LLAMA-bin-macos-arm64.tar.gz" -o /tmp/llama-mac.tar.gz
  rm -rf /tmp/llama-mac && mkdir -p /tmp/llama-mac && tar -xzf /tmp/llama-mac.tar.gz -C /tmp/llama-mac
  mkdir -p Vendor/llama-bin
  cp -R "$(dirname "$(find /tmp/llama-mac -name llama-server -type f | head -1)")"/. Vendor/llama-bin/
fi
echo "Готово: Vendor/whisper.xcframework и Vendor/llama-bin"
