#!/usr/bin/env bash
# Build a Release .app (ad-hoc signed) and package it into a .dmg.
# Output: dist/<AppName>-<version>.dmg  (also prints the dmg's sha256).
# The app name is read from project.yml, so a rename needs no edit here.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="$(awk '/^name:/{print $2; exit}' project.yml)"
SCHEME="${APP_NAME}"
BUILD_DIR="build"
DIST_DIR="dist"

# Version comes from project.yml (CFBundleShortVersionString) — the source of truth.
VERSION="$(/usr/bin/grep -A1 'CFBundleShortVersionString' project.yml | /usr/bin/grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)"
if [[ -z "${VERSION}" ]]; then
  echo "Could not read CFBundleShortVersionString from project.yml" >&2
  exit 1
fi
echo "==> Building ${APP_NAME} ${VERSION}"

# Always regenerate the project from project.yml first (matches the Makefile flow).
xcodegen generate

# Clean Release build.
xcodebuild -project "${APP_NAME}.xcodeproj" -scheme "${SCHEME}" \
  -configuration Release -derivedDataPath "${BUILD_DIR}" \
  clean build

APP_PATH="${BUILD_DIR}/Build/Products/Release/${APP_NAME}.app"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "Build product not found at ${APP_PATH}" >&2
  exit 1
fi

# Stage a folder with the app + an /Applications symlink (drag-to-install layout).
STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT
cp -R "${APP_PATH}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

mkdir -p "${DIST_DIR}"
DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"
rm -f "${DMG_PATH}"

echo "==> Creating ${DMG_PATH}"
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGING}" \
  -ov -format UDZO \
  "${DMG_PATH}"

echo "==> Done: ${DMG_PATH}"
shasum -a 256 "${DMG_PATH}"
