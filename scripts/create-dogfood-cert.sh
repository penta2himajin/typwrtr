#!/usr/bin/env bash
# Creates a self-signed Code Signing identity in the login keychain so dogfood
# builds keep a stable designated requirement across rebuilds (TCC/Accessibility).
#
# Idempotent. Local use only — not notarized / not for distribution.
set -euo pipefail

CERT_NAME="${TYPWRTR_DEV_CERT_NAME:-Typwrtr Dogfood}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
if [[ ! -f "$KEYCHAIN" ]]; then
  KEYCHAIN="${HOME}/Library/Keychains/login.keychain"
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_NAME"; then
  echo "Code-signing identity already present: $CERT_NAME"
  security find-identity -v -p codesigning | grep -F "$CERT_NAME" || true
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" \
  -out "$TMP/cert.pem" \
  -days 3650 \
  -subj "/CN=${CERT_NAME}" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning"

# OpenSSL 3 PKCS#12 defaults break `security import` (MAC verification failed).
P12_PW="$(openssl rand -hex 16)"
if ! openssl pkcs12 -export -legacy \
  -macalg sha1 \
  -keypbe PBE-SHA1-3DES \
  -certpbe PBE-SHA1-3DES \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$CERT_NAME" -out "$TMP/cert.p12" -passout pass:"$P12_PW" 2>/dev/null
then
  openssl pkcs12 -export -legacy \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$CERT_NAME" -out "$TMP/cert.p12" -passout pass:"$P12_PW"
fi

security import "$TMP/cert.p12" \
  -k "$KEYCHAIN" \
  -P "$P12_PW" \
  -A \
  -T /usr/bin/codesign \
  -T /usr/bin/security

# Trust for code signing (user domain). May prompt once.
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null || true

if [[ -n "${KEYCHAIN_PASSWORD:-}" ]]; then
  security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || true
fi

echo "Created self-signed code-signing identity: $CERT_NAME"
security find-identity -v -p codesigning | grep -F "$CERT_NAME" || {
  echo "WARNING: identity not yet listed as valid."
  echo "Open Keychain Access → find '${CERT_NAME}' → Trust → Code Signing = Always Trust"
  exit 1
}
