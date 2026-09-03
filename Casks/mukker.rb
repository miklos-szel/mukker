# Homebrew cask for Mukker. This repo doubles as its own tap, so the file is
# live — `version` and `sha256` always describe the latest published release,
# and `.github/workflows/release.yml` rewrites both when a `v*` tag is built.
#
# Install:
#   brew tap miklos-szel/mukker https://github.com/miklos-szel/mukker
#   brew install --cask miklos-szel/mukker/mukker
cask "mukker" do
  version "1.0.0"
  sha256 "61ab0dd9b5b7fe66d8331793c500cebfd815afff1c994eef18d3171c4e69b022"

  url "https://github.com/miklos-szel/mukker/releases/download/v#{version}/Mukker-#{version}.dmg"
  name "Mukker"
  desc "Menu-bar clipboard history, snippets, and screen capture with annotation"
  homepage "https://github.com/miklos-szel/mukker"

  depends_on macos: :sonoma

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
