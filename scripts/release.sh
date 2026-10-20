#!/bin/bash
# Builds the downloadable build/release-<version>/YapYap.dmg. Usage:
#   scripts/release.sh 1.0.0              build, sign and package; nothing leaves this Mac
#   scripts/release.sh 1.0.0 --notarize   also notarize with Apple, staple the ticket, and add the
#                                         release to site/appcast.xml for automatic updates
# The build number counts up on its own (one more than the releases in site/appcast.xml), because
# Sparkle uses it to decide what is newer. Override with BUILD=n.
# Notarizing needs a Developer ID Application certificate and credentials saved once with
#   xcrun notarytool store-credentials yapyap-notary --apple-id <id> --team-id <team>
# Signing updates needs the Sparkle private key in the login keychain (generate_keys, once).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [--notarize]}"
NOTARIZE=false
[[ " $* " == *" --notarize "* ]] && NOTARIZE=true
APPCAST=site/appcast.xml
BUILD="${BUILD:-$(( $(grep -c '<item>' "$APPCAST" 2>/dev/null || true) + 1 ))}"
REPO_URL=https://github.com/WannaBeSolopreneur/YapYap

VERSION=$VERSION BUILD=$BUILD scripts/build-app.sh
APP=build/YapYap.app
SIGNER=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)
if $NOTARIZE && [[ "$SIGNER" != Developer\ ID\ Application* ]]; then
    echo "error: signed by '$SIGNER'; notarizing needs a Developer ID Application certificate" >&2
    exit 1
fi

# The disk image: YapYap and an Applications shortcut on a branded background with an arrow
# (scripts/dmg/), and the app icon on the disk. Always named YapYap.dmg, so
# https://github.com/…/releases/latest/download/YapYap.dmg is the newest version.
# dmgbuild (pinned) lives in a private venv under .build/, set up on first use.
DMGBUILD=.build/dmgbuild-venv/bin/dmgbuild
if [[ ! -x "$DMGBUILD" ]]; then
    PY=$(command -v python3.13 python3.12 python3.11 python3.10 | head -1)
    [[ -n "$PY" ]] || { echo "error: dmgbuild needs Python 3.10+ (brew install python)" >&2; exit 1; }
    "$PY" -m venv .build/dmgbuild-venv
    .build/dmgbuild-venv/bin/pip install -q dmgbuild==1.6.7
fi
OUT=build/release-$VERSION
DMG=$OUT/YapYap.dmg
rm -rf "$OUT" && mkdir -p "$OUT"
"$DMGBUILD" -s scripts/dmg/settings.py -D app="$APP" "YapYap" "$DMG" >/dev/null
if [[ "$SIGNER" == Developer\ ID* ]]; then
    codesign --force --timestamp --sign "$SIGNER" "$DMG"
fi

if ! $NOTARIZE; then
    echo "Built $DMG $VERSION ($BUILD), signed by $SIGNER, not notarized"
    shasum -a 256 "$DMG"
    exit 0
fi

xcrun notarytool submit "$DMG" --keychain-profile yapyap-notary --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

# Add this release to the update feed. sign_update prints: sparkle:edSignature="…" length="…"
SIGN_UPDATE=.build/release/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
ATTRS=$("$SIGN_UPDATE" "$DMG")
ITEM="    <item>
      <title>YapYap $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$REPO_URL/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url=\"$REPO_URL/releases/download/v$VERSION/YapYap.dmg\" type=\"application/octet-stream\" $ATTRS/>
    </item>"
# Newest first, right after the channel header.
ITEM="$ITEM" perl -0pi -e 's/(<language>en<\/language>\n)/$1$ENV{ITEM}\n/' "$APPCAST"

echo "Notarized $DMG $VERSION ($BUILD); added it to $APPCAST"
shasum -a 256 "$DMG"
echo "Next: publish the GitHub release v$VERSION with $DMG, then deploy the site (web/build.sh) for the update feed."
