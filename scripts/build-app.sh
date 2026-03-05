#!/bin/bash
# Build Clipz.app — a self-contained macOS application bundle.
#
# Usage:
#   ./scripts/build-app.sh           # build
#   ./scripts/build-app.sh --open    # build and open in Finder
#   ./scripts/build-app.sh --run     # build and launch the app
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Clipz"
APP="$PROJECT/$APP_NAME.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"

# ── 1. Build Zig backend ──────────────────────────────────────────────────────
echo "▸ Building Zig backend (ReleaseSafe)..."
cd "$PROJECT"
zig build -Doptimize=ReleaseSafe

# ── 2. Build Rust frontend ────────────────────────────────────────────────────
echo "▸ Building Rust frontend (release)..."
cargo build --release -p clipz-gpui

# ── 3. Assemble .app bundle ───────────────────────────────────────────────────
echo "▸ Assembling $APP_NAME.app..."
rm -rf "$APP"
mkdir -p "$MACOS"
mkdir -p "$RESOURCES/bin"

cp "$PROJECT/target/release/clipz-gpui"  "$MACOS/clipz-gpui"
cp "$PROJECT/zig-out/bin/clipz"          "$RESOURCES/bin/clipz"
cp "$PROJECT/gpui-app/Info.plist"        "$APP/Contents/Info.plist"
cp "$PROJECT/gpui-app/AppIcon.icns"      "$RESOURCES/AppIcon.icns"

# ── 4. Ad-hoc code sign (required on Apple Silicon; skips Gatekeeper prompt) ─
echo "▸ Ad-hoc code signing..."
codesign --force --deep --sign - "$APP"

# ── 5. Create DMG ────────────────────────────────────────────────────────────
DMG="$PROJECT/$APP_NAME.dmg"
echo "▸ Creating $APP_NAME.dmg..."

DMG_STAGING="$PROJECT/.dmg-staging"
rm -rf "$DMG_STAGING" "$DMG"
mkdir -p "$DMG_STAGING"
cp -r "$APP" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create "$DMG" \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov

rm -rf "$DMG_STAGING"

echo ""
echo "✓ Built: $APP"
echo "✓ Built: $DMG"
echo ""
echo "To install: open \"$DMG\" and drag Clipz to Applications"
echo "To run:     open \"$APP\""
echo ""

# Optional flags
case "${1:-}" in
  --open) open -R "$APP" ;;          # reveal in Finder
  --run)  open "$APP" ;;             # launch
esac
