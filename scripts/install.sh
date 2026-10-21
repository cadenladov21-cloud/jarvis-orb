#!/bin/zsh
# Build a Release copy, install it as ~/Applications/JarvisOrb.app and start it.
# The installed copy's first launch turns on Open at Login (switch it off from the orb's menu).
# Signed with the local "JarvisOrb Local Signing" certificate when present (see CLAUDE.md).
set -euo pipefail

root="${0:A:h:h}"
derived="$root/build/DerivedData"

# Optional local.env (not in git) sets this Mac's own values, e.g. BUNDLE_ID=com.yourname.JarvisOrb.
# Keep the bundle id stable: macOS ties permissions and settings to it.
bundle_id=""
[[ -f "$root/local.env" ]] && source "$root/local.env" && bundle_id="${BUNDLE_ID:-}"
target="$HOME/Applications/JarvisOrb.app"

xcodebuild -project "$root/app/JarvisOrb.xcodeproj" -scheme JarvisOrb -configuration Release \
  -derivedDataPath "$derived" -quiet build ${bundle_id:+PRODUCT_BUNDLE_IDENTIFIER=$bundle_id}

mkdir -p "$HOME/Applications"
pkill -x JarvisOrb 2>/dev/null && sleep 1 || true
rm -rf "$target"
ditto "$derived/Build/Products/Release/JarvisOrb.app" "$target"

# Sign with the owner's local certificate when it exists, so macOS sees every build as the same
# app and keeps its permissions (Accessibility). Without it the build stays ad-hoc signed.
identity="JarvisOrb Local Signing"
if security find-identity -p codesigning | grep -q "\"$identity\""; then
  codesign --force --sign "$identity" --timestamp=none "$target"
else
  echo "Note: no \"$identity\" certificate; permissions will need re-granting after each install."
fi
open "$target"
echo "Installed $target"
