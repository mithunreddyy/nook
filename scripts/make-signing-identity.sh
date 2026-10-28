#!/bin/sh
# Creates "Nook Local Signing", a self-signed code-signing identity in your login
# keychain, so every build of Nook carries the same signature and macOS keeps its
# Accessibility permission across rebuilds. Run it yourself once:
#   scripts/make-signing-identity.sh
# Remove it any time in Keychain Access (search "Nook Local Signing").
set -e
NAME="Nook Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists."; exit 0
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cfg" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:nook 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:nook
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P nook -T /usr/bin/codesign
echo "Created \"$NAME\". Build with: NOOK_SIGN_IDENTITY=\"$NAME\" scripts/bundle.sh --install"
