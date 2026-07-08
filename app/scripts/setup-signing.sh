#!/usr/bin/env bash
# Creates a stable self-signed "Code Signing" identity in a dedicated keychain.
#
# Why: macOS ties the Accessibility (TCC) grant to the app's code signature.
# Ad-hoc signatures (codesign -s -) change on every build, so the grant never
# sticks and gestures silently go dead after a rebuild. A stable self-signed
# identity fixes this — no Apple Developer account or trust required, only a
# *consistent* signature.
#
# Run once. build.sh then signs with this identity automatically.
# Teardown: security delete-keychain "$HOME/Library/Keychains/altdrag-signing.keychain-db"
set -euo pipefail

CERT_NAME="AltDrag Local Signing"
KC="$HOME/Library/Keychains/altdrag-signing.keychain-db"
KC_PASS="altdrag"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cfg" <<'CFG'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = AltDrag Local Signing
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CFG

echo "==> Generating self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -nodes -config "$WORK/cfg" 2>/dev/null

# Legacy PKCS12 encryption (SHA1/3DES) so macOS `security import` can read it.
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/id.p12" -passout pass:"$KC_PASS" -name "$CERT_NAME" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

echo "==> Creating dedicated keychain and importing identity"
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KC_PASS" "$KC"
security set-keychain-settings "$KC"            # disable auto-lock timeout
security unlock-keychain -p "$KC_PASS" "$KC"
security import "$WORK/id.p12" -k "$KC" -P "$KC_PASS" -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null

# Add to the user keychain search list, preserving existing entries.
EXISTING=$(security list-keychains -d user | sed -e 's/"//g' -e 's/^[[:space:]]*//')
security list-keychains -d user -s "$KC" $EXISTING

echo "==> Done. '$CERT_NAME' is ready; rebuild with build.sh."
