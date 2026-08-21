# Homebrew cask template for Mukker.
#
# This file lives in the separate tap repo `miklos-szel/homebrew-mukker`
# (path: Casks/mukker.rb). It is kept here only as a reference/template.
# On each release: update `version` and `sha256` to match the published DMG.
#
# Install:  brew install --cask miklos-szel/mukker/mukker
cask "mukker" do
  version "0.4.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/miklos-szel/mukker/releases/download/v#{version}/Mukker-#{version}.dmg"
  name "Mukker"
  desc "Menu-bar clipboard history, snippets, and screen capture with annotation"
  homepage "https://github.com/miklos-szel/mukker"

  depends_on macos: ">= :sonoma"

  app "Mukker.app"

  # The app is ad-hoc signed (no Developer ID / notarization), so strip the
  # quarantine flag on install to avoid the Gatekeeper "damaged/unverified" block.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Mukker.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/Mukker",
    "~/Library/Preferences/com.mukker.Mukker.plist",
  ]
end
