# Homebrew cask for Mukker. This repo doubles as its own tap, so the file is
# live — `version` and `sha256` always describe the latest published release,
# and `.github/workflows/release.yml` rewrites both when a `v*` tag is built.
#
# Install:
#   brew tap miklos-szel/mukker https://github.com/miklos-szel/mukker
#   brew install --cask miklos-szel/mukker/mukker
cask "mukker" do
  version "1.3.3"
  sha256 "4af4ee194865c3b73ca86cbcab37dd5dae619a4fa71ce27307e0d244bfa80663"

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
