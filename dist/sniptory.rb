# Homebrew cask template for Sniptory.
#
# This file lives in the separate tap repo `miklos-szel/homebrew-sniptory`
# (path: Casks/sniptory.rb). It is kept here only as a reference/template.
# On each release: update `version` and `sha256` to match the published DMG.
#
# Install:  brew install --cask miklos-szel/sniptory/sniptory
cask "sniptory" do
  version "0.1.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/miklos-szel/sniptory/releases/download/v#{version}/Sniptory-#{version}.dmg"
  name "Sniptory"
  desc "Menu-bar clipboard history and snippets utility"
  homepage "https://github.com/miklos-szel/sniptory"

  depends_on macos: ">= :sonoma"

  app "Sniptory.app"

  # The app is ad-hoc signed (no Developer ID / notarization), so strip the
  # quarantine flag on install to avoid the Gatekeeper "damaged/unverified" block.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Sniptory.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/Sniptory",
    "~/Library/Preferences/com.sniptory.Sniptory.plist",
  ]
end
