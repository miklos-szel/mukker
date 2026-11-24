# Homebrew cask for Mukker. This repo doubles as its own tap, so the file is
# live — `version` and `sha256` always describe the latest published release,
# and `.github/workflows/release.yml` rewrites both when a `v*` tag is built.
#
# Install:
#   brew tap miklos-szel/mukker https://github.com/miklos-szel/mukker
#   brew install --cask miklos-szel/mukker/mukker
cask "mukker" do
  version "1.4.1"
  sha256 "209e373057fa1858f200adf2259ea068bec65be8dc0b9d5cf17e3f06c2e67c80"

  url "https://github.com/miklos-szel/mukker/releases/download/v#{version}/Mukker-#{version}.dmg"
  name "Mukker"
  desc "Menu-bar clipboard history, snippets, and screen capture with annotation"
  homepage "https://github.com/miklos-szel/mukker"

  depends_on macos: :sonoma

  app "Mukker.app"

  # The app is ad-hoc signed (no Developer ID / notarization), so strip the
  # quarantine flag on install to avoid the Gatekeeper "damaged/unverified" block.
  # Declarative install steps rather than a Ruby `postflight` block, which
  # Homebrew deprecated.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Mukker.app"]
  end

  zap trash: [
    "~/Library/Application Support/Mukker",
    "~/Library/Preferences/com.mukker.Mukker.plist",
  ]
end
