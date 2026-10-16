#!/usr/bin/env bash
#
# Creates a self-signed code-signing identity for local development and
# imports it into a keychain (the login keychain by default). Run once.
#
# Why: an ad-hoc signature's cdhash changes on every rebuild, and macOS ties
# the Accessibility grant to it, so every build used to revoke access.
# Signed with a stable certificate, the app's designated requirement stays the
# same across rebuilds and the grant survives.
#
#   scripts/make-signing-identity.sh                 # login keychain
#   KEYCHAIN=/path/to/x.keychain-db scripts/make-signing-identity.sh
#
# Nothing here is trusted system-wide or usable for distribution.

set -euo pipefail

NAME="${WICHER_SIGN_IDENTITY:-Wicher Development}"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "✓ \"$NAME\" already exists in $KEYCHAIN"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# A throwaway passphrase: `security import` rejects empty-password PKCS#12.
PASS="wicher-$$"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$PASS"

security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "✓ Created code-signing identity \"$NAME\" in $KEYCHAIN"
echo "  scripts/build.sh will use it from now on. Grant Accessibility once more after the next build."
