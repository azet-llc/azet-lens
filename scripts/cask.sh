#!/bin/zsh
# Prints the Homebrew cask for a release: scripts/cask.sh <version> <sha256 of the dmg>
set -euo pipefail
cat <<CASK
cask "mwoyea" do
  version "${1:?version}"
  sha256 "${2:?sha256}"

  url "https://github.com/midagedev/mwoyea/releases/download/v#{version}/Mwoyea-#{version}-arm64.dmg"
  name "Mwoyea"
  desc "Live, in-place screen translation"
  homepage "https://github.com/midagedev/mwoyea"

  depends_on arch: :arm64

  app "Mwoyea.app"

  zap trash: "~/Library/Preferences/dev.midagedev.mwoyea.plist"

  caveats <<~EOS
    Mwoyea needs macOS 27 and Screen Recording permission (asked on first launch).
    The first text recognition after launch can take up to a minute while the model loads.
  EOS
end
CASK
