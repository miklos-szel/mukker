#!/usr/bin/env bash
# Rename the app.
#
# Everything that carries the product name lives in project.yml (plus the repo URL
# in App/Support/Branding.swift and the headings in the docs) — source directories
# are named App/ and AppTests/, and the Makefile reads the scheme out of
# project.yml, so nothing moves on disk.
#
# No Swift file needs editing: user-facing names come from Branding.name at
# runtime, and the Swift module is pinned to AppCore via PRODUCT_MODULE_NAME, so
# the tests' `@testable import AppCore` keeps working across renames.
#
#   ./scripts/rename.sh Clipper                       # product name only
#   ./scripts/rename.sh Clipper --bundle-id com.me.Clipper
#   ./scripts/rename.sh Clipper --repo https://github.com/me/clipper
#
# NOT renamed on purpose (see App/Support/Branding.swift):
#   * Branding.supportFolderName  — the Application Support folder holding the
#     database and its sidecars. Changing it orphans every existing user's data.
#     (The app's first-run migrator can adopt a folder left behind by a rename,
#     but the frozen name means it never has to.)
#   * Branding.snippetExportFormat — the wire format string in exported snippet
#     files. Changing it makes older exports unreadable.
set -euo pipefail

cd "$(dirname "$0")/.."

NEW_NAME="${1:-}"
if [[ -z "${NEW_NAME}" ]]; then
  echo "usage: $0 <NewName> [--bundle-id com.example.NewName] [--repo URL]" >&2
  exit 1
fi
shift

NEW_BUNDLE_ID=""
NEW_REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-id) NEW_BUNDLE_ID="${2:?--bundle-id needs a value}"; shift 2 ;;
    --repo)      NEW_REPO="${2:?--repo needs a value}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

OLD_NAME="$(awk '/^name:/{print $2; exit}' project.yml)"
if [[ "${OLD_NAME}" == "${NEW_NAME}" ]]; then
  echo "Already named ${NEW_NAME} — nothing to do."
  exit 0
fi
echo "==> Renaming ${OLD_NAME} → ${NEW_NAME}"

# project.yml: top-level name, the app target key, CFBundleName/DisplayName,
# the TEST_HOST path, and the usage-description string.
sed -i '' \
  -e "s/^name: ${OLD_NAME}$/name: ${NEW_NAME}/" \
  -e "s/^  ${OLD_NAME}:$/  ${NEW_NAME}:/" \
  -e "s/^      - target: ${OLD_NAME}$/      - target: ${NEW_NAME}/" \
  -e "s/CFBundleName: ${OLD_NAME}/CFBundleName: ${NEW_NAME}/" \
  -e "s/CFBundleDisplayName: ${OLD_NAME}/CFBundleDisplayName: ${NEW_NAME}/" \
  -e "s|/${OLD_NAME}.app/Contents/MacOS/${OLD_NAME}|/${NEW_NAME}.app/Contents/MacOS/${NEW_NAME}|" \
  -e "s/${OLD_NAME} needs Accessibility access/${NEW_NAME} needs Accessibility access/" \
  project.yml

# Info.plist (regenerated values live in project.yml, but keep the checked-in
# template consistent so a raw xcodebuild sees the same thing).
sed -i '' \
  -e "s|<string>${OLD_NAME}</string>|<string>${NEW_NAME}</string>|g" \
  -e "s/${OLD_NAME} needs Accessibility access/${NEW_NAME} needs Accessibility access/" \
  App/Resources/Info.plist

if [[ -n "${NEW_BUNDLE_ID}" ]]; then
  OLD_BUNDLE_ID="$(awk '/PRODUCT_BUNDLE_IDENTIFIER:/{print $2; exit}' project.yml)"
  echo "==> Bundle ID ${OLD_BUNDLE_ID} → ${NEW_BUNDLE_ID}"
  echo "    (existing installs will start with fresh permissions; the first-run"
  echo "     migrator still adopts the old database from Application Support)"
  sed -i '' -e "s|${OLD_BUNDLE_ID}|${NEW_BUNDLE_ID}|g" project.yml App/Resources/Info.plist
fi

if [[ -n "${NEW_REPO}" ]]; then
  sed -i '' -e "s|static let repoURL = URL(string: \".*\")!|static let repoURL = URL(string: \"${NEW_REPO}\")!|" \
    App/Support/Branding.swift
fi

# Docs: headings and prose — but NOT the lines that document frozen identity.
# The data folder, the database file, the export format, the bundle ID and the
# exporter type names deliberately do not follow a rename, so a blanket sed here
# silently rewrites accurate documentation into lies. Those lines are skipped.
# Derived from the frozen constants themselves, so this list can't go stale the
# way a hardcoded one did once the identity moved.
rx() { printf '%s' "$1" | sed 's/[].[^$()*+?{}|\\]/\\&/g'; }
FROZEN_FOLDER="$(sed -n 's/.*supportFolderName = "\(.*\)".*/\1/p' App/Support/Branding.swift)"
FROZEN_DB="$(sed -n 's/.*databaseFileName = "\(.*\)".*/\1/p' App/Support/Branding.swift)"
FROZEN_FORMAT="$(sed -n 's/.*snippetExportFormat = "\(.*\)".*/\1/p' App/Support/Branding.swift)"
FROZEN_BUNDLE="$(awk '/PRODUCT_BUNDLE_IDENTIFIER:/{print $2; exit}' project.yml)"
PROTECTED="$(rx "${FROZEN_DB}")|$(rx "${FROZEN_FORMAT}")|$(rx "${FROZEN_BUNDLE}")"
PROTECTED="${PROTECTED}|Application Support/$(rx "${FROZEN_FOLDER}")"
PROTECTED="${PROTECTED}|supportFolderName|databaseFileName|snippetExportFormat|acceptedFormats"

for doc in README.md CLAUDE.md CHANGELOG.md; do
  [[ -f "${doc}" ]] || continue
  perl -i -pe "next if m{${PROTECTED}}; s/\Q${OLD_NAME}\E/${NEW_NAME}/g" "${doc}"
done

# The generated project carries the old name in its bundle path — drop it.
rm -rf "${OLD_NAME}.xcodeproj" build
xcodegen generate

echo "==> Done. Run 'make build' to verify."
echo "    Data locations are unchanged (Branding.supportFolderName is frozen)."
