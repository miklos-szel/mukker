#!/usr/bin/env bash
# Downloads the pinned transcribe.cpp native build (Dictation's engine) into native/win-x64/.
#
#   scripts/fetch-native.sh
#
# transcribe.cpp v0.4.2 (MIT) — the same version as the Mac app's Vendor/TranscribeCpp. Only an
# x86_64 Windows build is published, so Dictation ships in the win-x64 Mukker.exe only (it runs
# emulated on Windows on ARM). The archive is checked against its SHA-256 before it is unpacked;
# nothing here is committed (native/ is git-ignored).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=0.4.2
ASSET="transcribe-native-${VERSION}-windows-x86_64-cpu-vulkan.tar.gz"
URL="https://github.com/handy-computer/transcribe.cpp/releases/download/v${VERSION}/${ASSET}"
SHA256=6094102cf57b404b050707ceb258b12ce647b92e801b5d46077214e5b030c8aa
DEST=native/win-x64

if [ -f "$DEST/.version" ] && [ "$(cat "$DEST/.version")" = "$SHA256" ]; then
  exit 0
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/$ASSET" "$URL"
actual="$(shasum -a 256 "$tmp/$ASSET" | awk '{print $1}')"
if [ "$actual" != "$SHA256" ]; then
  echo "checksum mismatch for $ASSET: $actual" >&2
  exit 1
fi
mkdir -p "$tmp/x"
tar -xzf "$tmp/$ASSET" -C "$tmp/x"
rm -rf "$DEST"
mkdir -p "$DEST"
cp "$tmp"/x/*/*.dll "$DEST/"
cp -R "$tmp"/x/*/licenses "$DEST/licenses"
echo "$SHA256" > "$DEST/.version"
echo "fetched transcribe.cpp $VERSION into $DEST"
