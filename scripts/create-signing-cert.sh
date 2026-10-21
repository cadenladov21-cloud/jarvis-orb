#!/bin/zsh
# Creates a self-signed code-signing certificate, "JarvisOrb Local Signing", in your login
# Keychain (valid 10 years, usable only by Apple's codesign tool). install.sh signs the app with
# it, so macOS sees every build as the same app and keeps its permissions (Accessibility, Full Disk
# Access) across updates. Without it the app is ad-hoc signed and those need granting again after
# each install. Run once; does nothing if the certificate already exists.
set -euo pipefail

name="JarvisOrb Local Signing"
if security find-identity -p codesigning | grep -q "\"$name\""; then
  echo "\"$name\" already exists."
  exit 0
fi

umask 077
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

cat > "$dir/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$dir/cert.cnf" \
  -keyout "$dir/key.pem" -out "$dir/cert.pem" 2>/dev/null
pass=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" -name "$name" \
  -out "$dir/identity.p12" -passout "pass:$pass"
security import "$dir/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$pass" -T /usr/bin/codesign
echo "Created \"$name\". scripts/install.sh will sign with it."
