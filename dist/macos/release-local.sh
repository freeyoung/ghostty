#!/usr/bin/env bash
# Build this Ghostty, wrap it up, and put it on a release of this repository, so
# that another Mac can have it without building it.
#
#   dist/macos/release-local.sh            build, package, publish
#   dist/macos/release-local.sh --install  and install it in /Applications
#   dist/macos/release-local.sh --keep     build and package, publish nothing
#   dist/macos/release-local.sh --full     build the Zig library again as well
#
# The library is only built again when a file under src/ is newer than it, or
# when --full says so: it takes about 10 minutes, where the app alone takes 2.
#
# What comes out is signed by this Mac and by nothing else, so a Mac that
# downloads it has to be told the file is not quarantined:
#
#   xattr -dr com.apple.quarantine /Applications/Ghostty.app
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app="$repo/macos/build/ReleaseLocal/Ghostty.app"
library="$repo/macos/GhosttyKit.xcframework/macos-arm64/libghostty-internal.a"

install=0
publish=1
full=0
for arg in "$@"; do
  case "$arg" in
    --install) install=1 ;;
    --keep) publish=0 ;;
    --full) full=1 ;;
    *) printf 'release-local: unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

cd "$repo"
if [[ -n "$(git status --porcelain)" ]]; then
  printf 'release-local: the working tree has changes that no commit carries.\n' >&2
  printf 'A release is named after a commit, so commit them or put them aside.\n' >&2
  exit 1
fi

# The Zig library, if it is older than what it is built from.
if [[ $full -eq 1 ]] || [[ ! -f $library ]] || [[ -n "$(find src build.zig build.zig.zon -newer "$library" -print -quit 2>/dev/null)" ]]; then
  printf 'Building the library. This is the long part.\n'
  zig build -Doptimize=ReleaseFast -Dxcframework-target=native
else
  printf 'The library is newer than everything it is built from, so it stands.\n'
fi

# Signed with this Mac's own certificate where there is one, so that the
# permissions macOS gives a build outlive the next build. signing-identity.sh
# beside this makes it. Without it the build is signed ad hoc, as Ghostty's own
# ReleaseLocal is, and every permission has to be granted again each time.
identity="${GHOSTTY_SIGN_IDENTITY:-Ghostty Local Signing}"
signing=()
if security find-identity -v -p codesigning | grep -qF "$identity"; then
  signing=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$identity")
else
  printf 'No certificate called "%s": signing ad hoc, and every permission\n' "$identity"
  printf 'this build has been given will have to be given again. dist/macos/signing-identity.sh\n'
  printf 'makes one.\n'
fi

printf 'Building the application.\n'
xcodebuild -project macos/Ghostty.xcodeproj \
  -configuration ReleaseLocal -arch arm64 ONLY_ACTIVE_ARCH=YES -quiet \
  "${signing[@]}"

[[ -d $app ]] || { printf 'release-local: %s is not there\n' "$app" >&2; exit 1; }
codesign --verify --deep --strict "$app"

# The version the library carries names the branch and the commit it was built
# from, which is not this commit unless the library was built again just now.
version="$("$app/Contents/MacOS/ghostty" +version | awk '/^  - version:/ {print $3}')"
version="${version%%-*}"
commit="$(git rev-parse --short HEAD)"
tag="local-$(date +%Y%m%d-%H%M)-$commit"
out="$(mktemp -d)/Ghostty-$tag.zip"
ditto -c -k --keepParent "$app" "$out"
printf 'Packaged %s (%s)\n' "$out" "$(du -h "$out" | cut -f1)"

if [[ $install -eq 1 ]]; then
  osascript -e 'tell application "Ghostty" to quit' >/dev/null 2>&1 || true
  sleep 2
  rm -rf /Applications/Ghostty.app
  ditto "$app" /Applications/Ghostty.app
  printf 'Installed /Applications/Ghostty.app\n'
fi

if [[ $publish -eq 0 ]]; then
  printf 'Kept the package. Nothing was published.\n'
  exit 0
fi

notes="$(mktemp)"
{
  printf 'Ghostty %s, built on %s from %s.\n\n' "$version" "$(hostname -s)" "$commit"
  printf 'What this build adds, and the key that asks for each of them:\n\n'
  git log --reverse --format='- %s' "$(git merge-base HEAD origin/main)..HEAD"
  printf '\n\nSigned by this Mac alone, so a Mac that downloads it needs:\n\n'
  printf '    xattr -dr com.apple.quarantine /Applications/Ghostty.app\n'
} > "$notes"

gh release create "$tag" "$out" \
  --repo "$(git remote get-url fork | sed -E 's#.*[:/]([^/]+/[^/]+)\.git#\1#')" \
  --title "Ghostty $version ($commit)" \
  --notes-file "$notes"
rm -f "$notes"
