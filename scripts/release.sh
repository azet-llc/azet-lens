#!/bin/zsh
# Builds, signs, notarizes and packages Mwoyea, and optionally publishes it from this Mac.
# Releases normally come from CI (.github/workflows/release.yml, on a v* tag); this is the same build, run locally.
#
#   scripts/release.sh 1.0.0             # → build/release/Mwoyea-1.0.0-arm64.dmg (notarized, stapled)
#   scripts/release.sh 1.0.0 --publish   # … then the GitHub release and the Homebrew cask
#
# Needs, on the release Mac:
#   MWOYEA_RELEASE_IDENTITY   "Developer ID Application: Name (TEAMID)"
#   notarization, either      MWOYEA_NOTARY_PROFILE (a `xcrun notarytool store-credentials` profile)
#                  or         MWOYEA_NOTARY_KEY (.p8 path) + MWOYEA_NOTARY_KEY_ID + MWOYEA_NOTARY_ISSUER_ID
#   xcodegen, and for --publish an authenticated `gh` with push access to midagedev/mwoyea and midagedev/homebrew-tap
set -euo pipefail

VERSION=${1:?usage: scripts/release.sh <version> [--publish]}
PUBLISH=${2:-}
ROOT=${0:A:h:h}
OUT=$ROOT/build/release
APP=$OUT/dd/Build/Products/Release/Mwoyea.app
DMG=$OUT/Mwoyea-$VERSION-arm64.dmg
IDENTITY=${MWOYEA_RELEASE_IDENTITY:?set MWOYEA_RELEASE_IDENTITY to your Developer ID Application identity}
TEAM=${IDENTITY##*\(}; TEAM=${TEAM%\)}

cd "$ROOT"
[[ -d tools/inpaint/models/MIGAN_512.mlpackage ]] || { echo "missing tools/inpaint/models/MIGAN_512.mlpackage" >&2; exit 1; }
if [[ -n "${MWOYEA_NOTARY_PROFILE:-}" ]]; then
  NOTARY=(--keychain-profile "$MWOYEA_NOTARY_PROFILE")
elif [[ -n "${MWOYEA_NOTARY_KEY:-}" && -n "${MWOYEA_NOTARY_KEY_ID:-}" && -n "${MWOYEA_NOTARY_ISSUER_ID:-}" ]]; then
  NOTARY=(--key "$MWOYEA_NOTARY_KEY" --key-id "$MWOYEA_NOTARY_KEY_ID" --issuer "$MWOYEA_NOTARY_ISSUER_ID")
else
  echo "set MWOYEA_NOTARY_PROFILE, or MWOYEA_NOTARY_KEY + MWOYEA_NOTARY_KEY_ID + MWOYEA_NOTARY_ISSUER_ID" >&2; exit 1
fi

echo "==> Build $VERSION"
rm -rf "$OUT"; mkdir -p "$OUT"
xcodegen generate >/dev/null
xcodebuild -project Mwoyea.xcodeproj -scheme Mwoyea -configuration Release -derivedDataPath "$OUT/dd" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" \
  MWOYEA_SIGN_IDENTITY="$IDENTITY" MWOYEA_TEAM="$TEAM" OTHER_CODE_SIGN_FLAGS=--timestamp \
  build > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }
codesign --verify --strict --deep --verbose=2 "$APP"
[[ -d "$APP/Contents/Resources/MIGAN_512.mlmodelc" ]] || { echo "the app has no inpainting model" >&2; exit 1; }

echo "==> Disk image"
STAGE=$OUT/stage
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Mwoyea.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Mwoyea -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp -s "$IDENTITY" "$DMG"

echo "==> Notarize"
xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo "$DMG"
echo "sha256 $SHA"

[[ "$PUBLISH" == --publish ]] || exit 0

echo "==> GitHub release v$VERSION"
gh release create "v$VERSION" "$DMG" --repo midagedev/mwoyea --title "Mwoyea $VERSION" --generate-notes

echo "==> Homebrew cask"
TAP=$OUT/homebrew-tap
gh repo clone midagedev/homebrew-tap "$TAP" -- --depth 1 -q
scripts/cask.sh "$VERSION" "$SHA" > "$TAP/Casks/mwoyea.rb"
git -C "$TAP" add -A
git -C "$TAP" commit -qm "mwoyea $VERSION"
git -C "$TAP" push -q
echo "brew install midagedev/tap/mwoyea"
