#!/bin/bash
# Builds the downloadable build/YapYap-<version>.dmg. Usage:
#   scripts/release.sh 1.0.0 [build-number]              build, sign and package; nothing leaves this Mac
#   scripts/release.sh 1.0.0 [build-number] --notarize   also send it to Apple and staple the ticket
# Notarizing needs a Developer ID Application certificate and credentials saved once with
#   xcrun notarytool store-credentials yapyap-notary --apple-id <id> --team-id <team>
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [build-number] [--notarize]}"
BUILD=1
[[ "${2:-}" =~ ^[0-9]+$ ]] && BUILD=$2
NOTARIZE=false
[[ " $* " == *" --notarize "* ]] && NOTARIZE=true

VERSION=$VERSION BUILD=$BUILD scripts/build-app.sh
APP=build/YapYap.app
SIGNER=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)
if $NOTARIZE && [[ "$SIGNER" != Developer\ ID\ Application* ]]; then
    echo "error: signed by '$SIGNER'; notarizing needs a Developer ID Application certificate" >&2
    exit 1
fi

# The disk image: the app and an Applications shortcut to drag it onto.
DMG=build/YapYap-$VERSION.dmg
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname YapYap -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" -quiet
if [[ "$SIGNER" == Developer\ ID* ]]; then
    codesign --force --timestamp --sign "$SIGNER" "$DMG"
fi

if $NOTARIZE; then
    xcrun notarytool submit "$DMG" --keychain-profile yapyap-notary --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
    echo "Notarized $DMG"
else
    echo "Built $DMG (signed by $SIGNER, not notarized)"
fi
shasum -a 256 "$DMG"
