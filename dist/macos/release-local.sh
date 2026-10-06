#!/usr/bin/env bash
# Build this Ghostty on this Mac, signed so that macOS keeps what it has
# granted it, and install it if asked.
#
#   dist/macos/release-local.sh            build it
#   dist/macos/release-local.sh --install  and install it in /Applications
#   dist/macos/release-local.sh --full     build the Zig library again as well
#
# The library is only built again when a file under src/ is newer than it, or
# when --full says so: it takes about 10 minutes, where the app alone takes 2.
#
# The name is the Xcode configuration's, ReleaseLocal, not a promise to
# publish: the builds that others download come from a tag, see
# .github/workflows/release-fork.yml, which builds with this script and sets
# GHOSTTY_VERSION_STRING to the release's version, 1.3.2-fork.1 for one. Left
# unset, the library names itself from git, 1.3.2-master+<hash>.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app="$repo/macos/build/ReleaseLocal/Ghostty.app"
library="$repo/macos/GhosttyKit.xcframework/macos-arm64/libghostty-internal.a"

install=0
full=0
for arg in "$@"; do
  case "$arg" in
    --install) install=1 ;;
    --full) full=1 ;;
    *) printf 'release-local: unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

cd "$repo"

# A version string is baked into the library, so one that is asked for means
# building the library again.
version_string="${GHOSTTY_VERSION_STRING:-}"
zig_version=()
if [[ -n $version_string ]]; then
  zig_version=("-Dversion-string=$version_string")
  full=1
fi

# What macOS is told. It takes only integers there: CFBundleShortVersionString
# is the version of Ghostty this is built from, 3 numbers and no -dev, and
# CFBundleVersion counts the commits, as upstream's own releases do. Which
# build of the fork it is goes in GhosttyCommit, which the About window shows.
base="$(sed -nE 's/^[[:space:]]*\.version = "([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' build.zig.zon | head -1)"
[[ -n $base ]] || { printf 'release-local: no version in build.zig.zon\n' >&2; exit 1; }
build_number="$(git rev-list --count HEAD)"
commit="$(git rev-parse --short HEAD)"

# The Zig library, if it is older than what it is built from.
if [[ $full -eq 1 ]] || [[ ! -f $library ]] || [[ -n "$(find src build.zig build.zig.zon -newer "$library" -print -quit 2>/dev/null)" ]]; then
  printf 'Building the library. This is the long part.\n'
  zig build -Doptimize=ReleaseFast -Dxcframework-target=native "${zig_version[@]}"
else
  printf 'The library is newer than everything it is built from, so it stands.\n'
fi

# Signed with this Mac's own certificate where there is one, so that the
# permissions macOS gives a build outlive the next build. signing-identity.sh
# beside this makes it. Without it the build is signed ad hoc, as Ghostty's own
# ReleaseLocal is, and every permission has to be granted again each time.
identity="${GHOSTTY_SIGN_IDENTITY:-Ghostty Local Signing}"
signing=()
sign_as=-
if security find-identity -v -p codesigning | grep -qF "$identity"; then
  signing=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$identity")
  sign_as="$identity"
else
  printf 'No certificate called "%s": signing ad hoc, and every permission\n' "$identity"
  printf 'this build has been given will have to be given again. dist/macos/signing-identity.sh\n'
  printf 'makes one.\n'
fi

printf 'Building the application.\n'
xcodebuild -project macos/Ghostty.xcodeproj \
  -configuration ReleaseLocal -arch arm64 ONLY_ACTIVE_ARCH=YES -quiet \
  MARKETING_VERSION="$base" CURRENT_PROJECT_VERSION="$build_number" \
  "${signing[@]}"

[[ -d $app ]] || { printf 'release-local: %s is not there\n' "$app" >&2; exit 1; }

# The plist holds GhosttyCommit as a literal, so it is written after the
# build, and the change voids the signature of the outer bundle: it is signed
# again as it was, with what it was signed with. What is nested is untouched.
/usr/libexec/PlistBuddy -c "Set :GhosttyCommit $commit" "$app/Contents/Info.plist"

# Upstream's Sparkle key comes out. The repository's plist carries the public
# key upstream signs its releases with, the same one Ghostty 1.3.1 ships, and
# Sparkle 2.9 installs an update when either its EdDSA signature or its code
# signature checks out -- so with that key a "Check for Updates" would replace
# this build with upstream's, our certificate notwithstanding. With no key,
# Sparkle falls back to the code signature alone, which upstream's Developer
# ID does not match, and rejects it.
/usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$app/Contents/Info.plist" 2>/dev/null || true
codesign --force --sign "$sign_as" \
  --preserve-metadata=entitlements,requirements,flags,runtime "$app"
codesign --verify --deep --strict "$app"
printf 'Built %s\n' "$app"

if [[ $install -eq 1 ]]; then
  osascript -e 'tell application "Ghostty" to quit' >/dev/null 2>&1 || true
  sleep 2
  rm -rf /Applications/Ghostty.app
  ditto "$app" /Applications/Ghostty.app
  printf 'Installed /Applications/Ghostty.app\n'
fi
