#!/bin/bash
# One-time setup: creates a self-signed code-signing certificate named
# "TabStack Local Signing" in your login keychain. Signing every build with the same
# certificate keeps TabStack's identity stable, so the Accessibility permission you
# grant once keeps working after rebuilds (ad-hoc signatures change on every build).
#
# Remove it later with:  security delete-identity -c "TabStack Local Signing"
set -euo pipefail

NAME="TabStack Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then
    echo "Certificate \"$NAME\" already exists."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

cat > cfg.cnf <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

# Use the system LibreSSL: OpenSSL 3+/4 (e.g. from Homebrew) writes PKCS#12 files with
# AES/SHA-256 protection that `security import` rejects ("MAC verification failed").
SSL=/usr/bin/openssl
$SSL req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cfg.cnf 2>/dev/null
$SSL pkcs12 -export -out id.p12 -inkey key.pem -in cert.pem -passout pass:tabstack
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P tabstack -T /usr/bin/codesign

echo "Created \"$NAME\". build.sh will use it automatically."
