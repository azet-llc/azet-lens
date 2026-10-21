#!/bin/zsh
# Mac App Store build: archive with Apple Distribution + the "AZET Lens Mac App Store" profile, export a signed .pkg.
#   scripts/mas.sh 1.0.0 [--upload]   → build/mas/AZET Lens.pkg
set -euo pipefail
VERSION=${1:?usage: scripts/mas.sh <version> [--upload]}
ROOT=${0:A:h:h}; OUT=$ROOT/build/mas
cd "$ROOT"
mkdir -p "$OUT"
xcodegen generate >/dev/null
xcodebuild -project Mwoyeo.xcodeproj -scheme Mwoyeo -configuration Release -archivePath "$OUT/Lens.xcarchive" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" \
  MWOYEO_SIGN_IDENTITY="Apple Distribution: AZET LLC (95P4H2RG24)" MWOYEO_TEAM=95P4H2RG24 \
  PROVISIONING_PROFILE_SPECIFIER="AZET Lens Mac App Store" OTHER_CODE_SIGN_FLAGS=--timestamp ENABLE_HARDENED_RUNTIME=NO \
  archive > "$OUT/archive.log" 2>&1 || { tail -30 "$OUT/archive.log"; exit 1; }
cat > "$OUT/export.plist" <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>method</key><string>app-store-connect</string><key>teamID</key><string>95P4H2RG24</string>
<key>signingStyle</key><string>manual</string><key>signingCertificate</key><string>Apple Distribution</string>
<key>installerSigningCertificate</key><string>3rd Party Mac Developer Installer</string>
<key>provisioningProfiles</key><dict><key>io.azet.lens</key><string>AZET Lens Mac App Store</string></dict></dict></plist>
P
xcodebuild -exportArchive -archivePath "$OUT/Lens.xcarchive" -exportOptionsPlist "$OUT/export.plist" -exportPath "$OUT" > "$OUT/export.log" 2>&1 || { tail -30 "$OUT/export.log"; exit 1; }
APP="$OUT/Lens.xcarchive/Products/Applications/AZET Lens.app"
ENT=$(codesign -d --entitlements :- "$APP" 2>/dev/null)
grep -q "com.apple.security.app-sandbox" <<<"$ENT" || { echo "the app is not sandboxed" >&2; exit 1; }
! grep -q "com.apple.security.network" <<<"$ENT" || { echo "the app has a network entitlement" >&2; exit 1; }
ls -la "$OUT"/*.pkg
if [[ ${2:-} == --upload ]]; then
  xcrun altool --upload-app -f "$OUT/AZET Lens.pkg" -t macos --apiKey "$(tkt get APPLE_AZET_ASC_API_KEY_ID)" --apiIssuer "$(tkt get APPLE_AZET_ASC_ISSUER_ID)"
fi
