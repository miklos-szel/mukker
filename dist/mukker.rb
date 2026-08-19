# Homebrew cask template for Mukker.
#
# This file lives in the separate tap repo `miklos-szel/homebrew-sniptory`
# (path: Casks/mukker.rb). It is kept here only as a reference/template.
# On each release: update `version` and `sha256` to match the published DMG.
#
# NOTE: the Homebrew tap still carries the project's former name; the app repo
# itself is now miklos-szel/mukker. Update the tap reference if it is renamed.
#
# Install:  brew install --cask miklos-szel/sniptory/mukker
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

  # Both identities are listed: the app copies (never moves) data forward when it
  # adopts a pre-rename install, so an uninstall should clean up either location.
  zap trash: [
    "~/Library/Application Support/Mukker",
    "~/Library/Application Support/Sniptory",
    "~/Library/Preferences/com.mukker.Mukker.plist",
    "~/Library/Preferences/com.sniptory.Sniptory.plist",
  ]
end
