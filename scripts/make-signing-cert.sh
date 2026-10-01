#!/bin/bash
# Creates a self-signed code-signing certificate, "NetPulse Local Signing",
# in the login keychain, for scripts/build-app.sh to sign with.
#
# Why: macOS remembers privacy grants (such as "access data from other
# apps") by the app's signing identity. Ad-hoc builds get a new one every
# time, so macOS asks again after each rebuild. Signed with this
# certificate, every build is the same app to macOS. No Apple Developer
# account needed; the certificate only works on this Mac.
#
# Run once. macOS asks for your login password to trust the certificate
# for code signing.
set -euo pipefail

NAME="NetPulse Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists; nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

# /usr/bin/openssl is LibreSSL, whose PKCS#12 output `security import` reads.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASS="netpulse-$$"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -passout "pass:$PASS" -out "$WORK/cert.p12"

security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
echo "==> trusting \"$NAME\" for code signing (macOS asks for your password)"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

security find-identity -v -p codesigning | grep "\"$NAME\"" \
  && echo "==> done; scripts/build-app.sh now signs with \"$NAME\""
