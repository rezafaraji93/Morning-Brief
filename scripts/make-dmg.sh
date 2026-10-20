#!/usr/bin/env bash
# Builds the app, then wraps it in a drag-to-Applications disk image: dist/MorningBrief-<version>.dmg
#
#   ./scripts/make-dmg.sh                         # unsigned DMG (works, but Gatekeeper warns)
#   SIGN_IDENTITY="Developer ID Application: Your Co (TEAMID)" NOTARY_PROFILE=morningbrief \
#   ARCHS="arm64 x86_64" ./scripts/make-dmg.sh    # signed + notarized: opens with no warnings
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
APP="dist/Morning Brief.app"
DMG="dist/MorningBrief-$VERSION.dmg"

# 1. Build and sign the .app (notarization happens once, on the DMG, below).
NOTARY_PROFILE="" ./scripts/build-app.sh

# 2. Stage the DMG contents: the app plus an Applications shortcut to drag it onto.
STAGE="$(mktemp -d)/Morning Brief"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Morning Brief" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

# 3. Sign and notarize the DMG. Notarizing the DMG covers the app inside it.
if [ "$SIGN_IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  if [ -n "$NOTARY_PROFILE" ]; then
    echo "==> Notarizing $DMG (usually 1-5 minutes)"
    KC_ARGS=()
    [ -n "${NOTARY_KEYCHAIN:-}" ] && KC_ARGS=(--keychain "$NOTARY_KEYCHAIN")
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" ${KC_ARGS[@]+"${KC_ARGS[@]}"} --wait
    xcrun stapler staple "$DMG"
  fi
fi

echo "==> Done: $DMG"
