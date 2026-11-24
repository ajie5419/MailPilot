#!/usr/bin/env bash
set -euo pipefail

CERT_NAME="MailPilot Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"${CERT_NAME}\""; then
  echo "Code signing certificate '${CERT_NAME}' already exists and is valid."
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/cert.cfg" <<EOF
[ req ]
default_bits       = 2048
distinguished_name = req_dn
x509_extensions    = v3_codesign
prompt             = no

[ req_dn ]
CN = ${CERT_NAME}

[ v3_codesign ]
basicConstraints       = critical,CA:FALSE
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
EOF

echo "1/3 Generating 10-year self-signed code signing certificate '${CERT_NAME}'..."
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP_DIR/key.pem" \
  -out "$TMP_DIR/cert.pem" \
  -days 3650 \
  -config "$TMP_DIR/cert.cfg" >/dev/null 2>&1

openssl pkcs12 -export \
  -legacy \
  -keypbe PBE-SHA1-3DES \
  -certpbe PBE-SHA1-3DES \
  -macalg sha1 \
  -out "$TMP_DIR/cert.p12" \
  -inkey "$TMP_DIR/key.pem" \
  -in "$TMP_DIR/cert.pem" \
  -passout pass:mailpilot-local

echo "2/3 Importing certificate into your login keychain..."
security import "$TMP_DIR/cert.p12" -k "$KEYCHAIN" -P mailpilot-local -T /usr/bin/codesign

echo "3/3 Marking '${CERT_NAME}' as trusted for code signing (macOS may prompt for your password)..."
security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP_DIR/cert.pem"

echo ""
echo "Verifying signing identity:"
security find-identity -v -p codesigning
echo ""
echo "Done! Now rebuild MailPilot with: ./scripts/build_app.sh"
