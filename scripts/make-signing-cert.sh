#!/bin/bash
# One-time: creates a self-signed "YapYap Local Signing" code-signing certificate in the login
# keychain, so builds keep the same signature and macOS keeps their permissions.
# Remove with: security delete-identity -c "YapYap Local Signing"
set -euo pipefail
NAME="YapYap Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then echo "Already have '$NAME'"; exit 0; fi
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
cat > "$DIR/cert.cnf" <<CNF
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
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$DIR/key.pem" -out "$DIR/cert.pem" -days 3650 -config "$DIR/cert.cnf" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -out "$DIR/id.p12" -passout pass:tmp -name "$NAME" 2>/dev/null
security import "$DIR/id.p12" -k ~/Library/Keychains/login.keychain-db -P tmp -T /usr/bin/codesign
echo "Created '$NAME'"
