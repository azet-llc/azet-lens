#!/bin/zsh
# One-time, on the Mac that holds the Developer ID certificate: puts the signing certificate and the notary key
# into the repository's GitHub secrets, which .github/workflows/release.yml uses.
#
#   1. Keychain Access › login › My Certificates › "Developer ID Application: …" › right-click › Export…
#      Save as devid.p12 (Desktop) and choose any password.
#   2. scripts/setup-release-secrets.sh ~/Desktop/devid.p12
#
# The notary key is read from ~/.appstoreconnect (credentials.env with ASC_KEY_ID and ASC_ISSUER_ID, and
# private_keys/AuthKey_<id>.p8), or from MWOYEO_NOTARY_KEY / MWOYEO_NOTARY_KEY_ID / MWOYEO_NOTARY_ISSUER_ID.
# Needs `gh` signed in with admin access to the repository. Nothing is printed; the .p12 is deleted afterwards.
set -euo pipefail

P12=${1:?usage: scripts/setup-release-secrets.sh <devid.p12>}
REPO=${REPO:-midagedev/mwoyeo}
[[ -f "$P12" ]] || { echo "no such file: $P12" >&2; exit 1; }

if [[ -z "${MWOYEO_NOTARY_KEY:-}" && -f ~/.appstoreconnect/credentials.env ]]; then
  source ~/.appstoreconnect/credentials.env
  MWOYEO_NOTARY_KEY_ID=$ASC_KEY_ID
  MWOYEO_NOTARY_ISSUER_ID=$ASC_ISSUER_ID
  MWOYEO_NOTARY_KEY=~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
fi
[[ -f "${MWOYEO_NOTARY_KEY:-}" ]] || { echo "no notary key found" >&2; exit 1; }

read -rs "PASSWORD?Password you gave the .p12: "; echo
# Check the password and the identity the way the release workflow will: import into a throwaway keychain.
KC=$(mktemp -d)/check.keychain-db
security create-keychain -p check "$KC"
trap 'security delete-keychain "$KC" 2>/dev/null' EXIT
security import "$P12" -k "$KC" -P "$PASSWORD" -t cert -f pkcs12 >/dev/null ||
  { echo "wrong password, or not a .p12" >&2; exit 1; }
security find-identity -v -p codesigning "$KC" | grep -q "Developer ID Application" ||
  { echo "no Developer ID Application identity in $P12" >&2; exit 1; }

base64 -i "$P12" | gh secret set MACOS_SIGN_P12 -R "$REPO"
printf '%s' "$PASSWORD" | gh secret set MACOS_SIGN_PASSWORD -R "$REPO"
gh secret set MACOS_NOTARY_KEY -R "$REPO" < "$MWOYEO_NOTARY_KEY"
printf '%s' "$MWOYEO_NOTARY_KEY_ID" | gh secret set MACOS_NOTARY_KEY_ID -R "$REPO"
printf '%s' "$MWOYEO_NOTARY_ISSUER_ID" | gh secret set MACOS_NOTARY_ISSUER_ID -R "$REPO"
rm -P "$P12"
gh secret list -R "$REPO"
