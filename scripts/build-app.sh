#!/bin/bash
# Builds and signs build/YapYap.app. Usage: scripts/build-app.sh [--install]
#   VERSION=1.0.0 BUILD=3   version shown in Finder / used by updates (default 0.1.0 / 1)
#   SIGN_IDENTITY=…         signing identity (default: "Developer ID Application" if installed,
#                           else "YapYap Local Signing", else ad-hoc)
#   TELEMETRYDECK_APP_ID=…  sends anonymous usage stats to that TelemetryDeck app (default: none)
# Private settings (like the App ID for official builds) go in scripts/local.env, which git ignores.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f scripts/local.env ]] && source scripts/local.env

BUNDLE_ID=cc.yapyap.app
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"

# xcodebuild, not `swift build`: MLX (Kokoro) needs its Metal shaders compiled.
# Its own build folder, with code coverage off: sharing .build/xcode with `xcodebuild test` let
# coverage instrumentation leak into release frameworks (1.0.0–1.0.3).
xcodebuild -scheme YapYap -destination 'platform=macOS,arch=arm64' -configuration Release \
    -derivedDataPath .build/release -quiet build \
    CLANG_COVERAGE_MAPPING=NO CLANG_ENABLE_CODE_COVERAGE=NO
PRODUCTS=.build/release/Build/Products/Release

APP=build/YapYap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$PRODUCTS/YapYap" "$APP/Contents/MacOS/YapYap"
cp -R "$PRODUCTS"/PackageFrameworks/*.framework "$APP/Contents/Frameworks/"
ditto "$PRODUCTS/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp -R "$PRODUCTS"/*.bundle "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/welcome-demo.mp4 "$APP/Contents/Resources/"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/YapYap" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>YapYap</string>
    <key>CFBundleDisplayName</key><string>YapYap</string>
    <key>CFBundleExecutable</key><string>YapYap</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>YapYap captures the window you ask it to read so it can find the words. Nothing leaves your Mac.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>YapYap listens only while you dictate (hold the shortcut, or tap it for hands-free) and types what you say. Speech is recognized on your Mac.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>YapYap turns what you say into text while you dictate.</string>
    <key>SUFeedURL</key><string>https://yapyap.cc/appcast.xml</string>
    <key>SUPublicEDKey</key><string>dO3+zMLp0xNh7JIBb0nV8XfRIdA2FY3JkwjiYRY95aw=</string>
    <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

# Anonymous usage stats (on by default in the app, can be turned off in Settings). Only builds
# given an App ID send anything; without one the setting is hidden and nothing leaves the Mac.
if [[ -n "${TELEMETRYDECK_APP_ID:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :TelemetryDeckAppID string $TELEMETRYDECK_APP_ID" "$APP/Contents/Info.plist"
fi

# macOS ties Screen Recording, Microphone and Accessibility grants to the signature, so builds
# need a fixed certificate: Developer ID for anything shared, or the self-signed local one
# (scripts/make-signing-cert.sh) for this Mac. Ad-hoc signatures change every build.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi
if [[ -z "$SIGN_IDENTITY" ]] && security find-certificate -c "YapYap Local Signing" >/dev/null 2>&1; then
    SIGN_IDENTITY="YapYap Local Signing"
fi
ENTITLEMENTS=scripts/YapYap.entitlements
if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "warning: no signing certificate; ad-hoc signing (permissions reset on every build)"
    SIGN_IDENTITY=-
    SIGN=(codesign --force --sign -)
elif [[ "$SIGN_IDENTITY" == Developer\ ID* ]]; then
    # Hardened runtime + secure timestamp: what notarization requires.
    SIGN=(codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY")
else
    # A self-signed certificate has no Team ID, so the hardened runtime's library validation
    # would refuse our own frameworks; allow them here only. Lets local builds run the same
    # hardened runtime as releases.
    ENTITLEMENTS=$(mktemp -t yapyap).plist
    cp scripts/YapYap.entitlements "$ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENTITLEMENTS"
    SIGN=(codesign --force --options runtime --sign "$SIGN_IDENTITY")
fi

# Inside out: Sparkle's helpers, then frameworks and resource bundles, then the app with its entitlements.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPARKLE/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPARKLE/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Updater.app"
for item in "$APP"/Contents/Frameworks/*.framework "$APP"/Contents/Resources/*.bundle; do
    "${SIGN[@]}" "$item"
done
"${SIGN[@]}" --identifier "$BUNDLE_ID" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict --deep "$APP"
echo "Built $APP $VERSION ($BUILD), signed by: $SIGN_IDENTITY"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x YapYap || true
    rm -rf /Applications/YapYap.app
    cp -R "$APP" /Applications/
    open /Applications/YapYap.app
    echo "Installed and launched /Applications/YapYap.app"
fi
