#!/bin/zsh
# Creates a self-signed code-signing certificate named "OmniCast Local" in your
# login keychain, for scripts/bundle.sh to sign with.
#
# Why: macOS ties Screen Recording, Camera and Mic permission to an app's
# signature. Ad-hoc signatures change on every build, so each rebuild loses the
# permission. With a fixed certificate the permission is granted once and kept.
#
# The certificate is only used on this Mac to sign OmniCast. It is not trusted
# for anything else and isn't added to any trust settings.
set -euo pipefail

name="OmniCast Local"
if security find-identity -p codesigning | grep -q "\"$name\""; then
	echo "\"$name\" already exists in your keychain. Nothing to do."
	exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pass=$(uuidgen)

cat >"$work/cert.cnf" <<EOF
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
EOF

# /usr/bin/openssl (LibreSSL) writes a PKCS#12 file the keychain can import.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
	-config "$work/cert.cnf" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
	-name "$name" -out "$work/cert.p12" -passout "pass:$pass"

# -T lets codesign use the key without asking each build.
security import "$work/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
	-P "$pass" -T /usr/bin/codesign

echo
echo "Created \"$name\". Rebuild with ./scripts/bundle.sh; it will sign with it."
echo "Then grant Screen Recording to OmniCast once more. It will stick from now on."
