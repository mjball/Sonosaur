#!/usr/bin/env bash
# Build a release .app, package it, and optionally publish to GitHub Releases.
#
# Usage:
#   ./Scripts/build-release.sh                  # build only
#   ./Scripts/build-release.sh --release v0.2.0 # build + create GitHub release
#
# Distribution strategy (same as mid-clock):
#   - App is unsigned; users strip quarantine with:  xattr -cr /Applications/Sonosaur.app
#   - Released as Sonosaur.app.zip via GitHub Releases on mjball/Sonosaur
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE_VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE_VERSION="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

ARCHIVE="$REPO_ROOT/Sonosaur.app.zip"
APP_BUILD_DIR="$REPO_ROOT/build"
APP_PATH="$APP_BUILD_DIR/Sonosaur.app"

echo "==> Cleaning previous build"
rm -rf "$APP_BUILD_DIR" "$ARCHIVE"

echo "==> Building Release configuration"
cd "$REPO_ROOT"
xcodebuild \
  -project Sonosaur.xcodeproj \
  -scheme Sonosaur \
  -configuration Release \
  -derivedDataPath "$APP_BUILD_DIR/DerivedData" \
  CONFIGURATION_BUILD_DIR="$APP_BUILD_DIR" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build | grep -E '^(Build|error:|warning:|.*\.swift:[0-9]+)' | grep -v 'appintents' || true

echo "==> Locating built app"
BUILT_APP=$(find "$APP_BUILD_DIR" -name "Sonosaur.app" -not -path "*/DerivedData/*" | head -1)
if [[ -z "$BUILT_APP" ]]; then
  BUILT_APP=$(find "$APP_BUILD_DIR/DerivedData" -name "Sonosaur.app" | head -1)
fi
echo "    Found: $BUILT_APP"
cp -R "$BUILT_APP" "$APP_PATH"

if [[ -n "$RELEASE_VERSION" ]]; then
  echo "==> Stamping version $RELEASE_VERSION"
  PLIST="$APP_PATH/Contents/Info.plist"
  plutil -replace CFBundleShortVersionString -string "${RELEASE_VERSION#v}" "$PLIST"
  plutil -replace CFBundleVersion -string "${RELEASE_VERSION#v}" "$PLIST"
fi

echo "==> Packaging"
cd "$APP_BUILD_DIR"
zip -qr "$ARCHIVE" Sonosaur.app
echo "    Created: $ARCHIVE ($(du -sh "$ARCHIVE" | cut -f1))"

if [[ -n "$RELEASE_VERSION" ]]; then
  echo "==> Creating GitHub release $RELEASE_VERSION"
  GH_HOST=github.com gh release create "$RELEASE_VERSION" "$ARCHIVE" \
    --repo mjball/Sonosaur \
    --title "Sonosaur $RELEASE_VERSION" \
    --notes "$(cat <<EOF
## Install

Download \`Sonosaur.app.zip\` from the assets below, double-click to extract, and drag \`Sonosaur.app\` to \`/Applications\`.

Then remove the macOS quarantine flag (required for unsigned apps):

\`\`\`bash
xattr -cr /Applications/Sonosaur.app
open /Applications/Sonosaur.app
\`\`\`
EOF
    )"
  echo "==> Released: https://github.com/mjball/Sonosaur/releases/tag/$RELEASE_VERSION"
else
  echo "==> Done. Run with --release v1.2.3 to publish to GitHub."
fi
