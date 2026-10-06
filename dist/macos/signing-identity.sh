#!/usr/bin/env bash
# Make the certificate this build is signed with, if this Mac has not got it.
#
# A build signed ad hoc has no identity beyond the hash of its own code, so
# macOS treats every rebuild as a different program: Screen Recording,
# Accessibility and every other permission granted to it is granted to that one
# build, and the next one starts again with nothing. A certificate of its own,
# even a self-signed one, is an identity that outlives a rebuild, and the
# permissions stay where they were put.
#
# The release workflow signs with the same certificate, so that a build
# downloaded from a release and a build made here are one program to macOS and
# share what it has granted. For that the identity, key and all, is exported
# from the keychain into 2 secrets of the repository; see
# .github/workflows/release-fork.yml. Self-signed, it proves nothing to anyone
# else, and anyone who wants their own runs this again.
set -euo pipefail

name="${GHOSTTY_SIGN_IDENTITY:-Ghostty Local Signing}"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -qF "$name"; then
  printf 'The certificate "%s" is already here.\n' "$name"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Code signing wants the Code Signing extended use and nothing else.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$work/key.pem" -out "$work/cert.pem" \
  -subj "/CN=$name/O=$USER" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# The keychain reads none of what OpenSSL 3 writes by default, hence the old
# algorithms, and -T lets codesign use the key without asking every time.
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
  -out "$work/id.p12" -passout pass:ghostty -name "$name" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

security import "$work/id.p12" -k "$keychain" -P ghostty \
  -T /usr/bin/codesign -T /usr/bin/security

security find-identity -v -p codesigning | grep -F "$name"
printf '\nBuilt with this from now on. The permissions macOS has given the old\n'
printf 'builds belong to those builds: grant them once more to the first build\n'
printf 'that carries this certificate, and they will hold from then on.\n'
