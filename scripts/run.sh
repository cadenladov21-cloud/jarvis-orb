#!/bin/zsh
# Build the app, stop any running copy, and launch the fresh build.
# Usage: scripts/run.sh [Debug|Release]
set -euo pipefail

root="${0:A:h:h}"
config="${1:-Debug}"
derived="$root/build/DerivedData"

# Optional local.env (not in git) sets this Mac's own values, e.g. BUNDLE_ID=com.yourname.JarvisOrb.
# Keep the bundle id stable: macOS ties permissions and settings to it.
bundle_id=""
[[ -f "$root/local.env" ]] && source "$root/local.env" && bundle_id="${BUNDLE_ID:-}"

xcodebuild -project "$root/app/JarvisOrb.xcodeproj" -scheme JarvisOrb -configuration "$config" \
  -derivedDataPath "$derived" -quiet build ${bundle_id:+PRODUCT_BUNDLE_IDENTIFIER=$bundle_id}

pkill -x JarvisOrb 2>/dev/null || true
open "$derived/Build/Products/$config/JarvisOrb.app"
