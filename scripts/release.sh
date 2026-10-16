#!/bin/zsh
# Builds, signs (AZET LLC Developer ID), notarizes and packages AZET Lens, and optionally publishes it from this Mac.
# There is no CI release: the signing key stays on the release Mac, never in repository secrets.
#
#   scripts/release.sh 1.0.0             # → build/release/AZET-Lens-1.0.0-arm64.dmg (notarized, stapled)
#   scripts/release.sh 1.0.0 --publish   # … then the GitHub release on azet-llc/azet-lens
#
# Needs, on the release Mac:
#   MWOYEO_RELEASE_IDENTITY   "Developer ID Application: Name (TEAMID)"
#   notarization, either      MWOYEO_NOTARY_PROFILE (a `xcrun notarytool store-credentials` profile)
#                  or         MWOYEO_NOTARY_KEY (.p8 path) + MWOYEO_NOTARY_KEY_ID + MWOYEO_NOTARY_ISSUER_ID
#   xcodegen, and for --publish an authenticated `gh` with push access to azet-llc/azet-lens
set -euo pipefail

VERSION=${1:?usage: scripts/release.sh <version> [--publish]}
PUBLISH=${2:-}
ROOT=${0:A:h:h}
OUT=$ROOT/build/release
APP="$OUT/dd/Build/Products/Release/AZET Lens.app"
DMG=$OUT/AZET-Lens-$VERSION-arm64.dmg
IDENTITY=${MWOYEO_RELEASE_IDENTITY:?set MWOYEO_RELEASE_IDENTITY to your Developer ID Application identity}
TEAM=${IDENTITY##*\(}; TEAM=${TEAM%\)}

cd "$ROOT"
[[ -d tools/inpaint/models/MIGAN_512.mlpackage ]] || { echo "missing tools/inpaint/models/MIGAN_512.mlpackage" >&2; exit 1; }
if [[ -n "${MWOYEO_NOTARY_PROFILE:-}" ]]; then
  NOTARY=(--keychain-profile "$MWOYEO_NOTARY_PROFILE")
elif [[ -n "${MWOYEO_NOTARY_KEY:-}" && -n "${MWOYEO_NOTARY_KEY_ID:-}" && -n "${MWOYEO_NOTARY_ISSUER_ID:-}" ]]; then
  NOTARY=(--key "$MWOYEO_NOTARY_KEY" --key-id "$MWOYEO_NOTARY_KEY_ID" --issuer "$MWOYEO_NOTARY_ISSUER_ID")
else
  echo "set MWOYEO_NOTARY_PROFILE, or MWOYEO_NOTARY_KEY + MWOYEO_NOTARY_KEY_ID + MWOYEO_NOTARY_ISSUER_ID" >&2; exit 1
fi

echo "==> Build $VERSION"
rm -rf "$OUT"; mkdir -p "$OUT"
xcodegen generate >/dev/null
xcodebuild -project Mwoyeo.xcodeproj -scheme Mwoyeo -configuration Release -derivedDataPath "$OUT/dd" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" \
  MWOYEO_SIGN_IDENTITY="$IDENTITY" MWOYEO_TEAM="$TEAM" OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }
codesign --verify --strict --deep --verbose=2 "$APP"
! codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow ||
  { echo "the app is signed with get-task-allow, which notarization rejects" >&2; exit 1; }
[[ -d "$APP/Contents/Resources/MIGAN_512.mlmodelc" ]] || { echo "the app has no inpainting model" >&2; exit 1; }
# The privacy promise is enforced by the sandbox: refuse to ship a build that could open a connection.
ENT=$(codesign -d --entitlements :- "$APP" 2>/dev/null)
grep -q "com.apple.security.app-sandbox" <<<"$ENT" || { echo "the app is not sandboxed" >&2; exit 1; }
! grep -q "com.apple.security.network" <<<"$ENT" || { echo "the app has a network entitlement" >&2; exit 1; }

echo "==> Disk image"
STAGE=$OUT/stage
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/AZET Lens.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "AZET Lens" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
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
gh release create "v$VERSION" "$DMG" --repo azet-llc/azet-lens --title "AZET Lens $VERSION" --generate-notes
