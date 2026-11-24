#!/usr/bin/env bash
# Builds self-contained single-file Mukker.exe for Windows on ARM and x64 into dist/<rid>/.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/fetch-native.sh   # Dictation's engine, bundled into the win-x64 build only
for rid in ${RIDS:-win-arm64 win-x64}; do
  dotnet publish src/Mukker.App -c Release -r "$rid" --self-contained \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true \
    -o "dist/$rid"
done
