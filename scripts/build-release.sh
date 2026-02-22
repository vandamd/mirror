#!/bin/bash
# Manual release build script — builds, signs, notarizes, and optionally uploads.
#
# Usage: ./scripts/build-release.sh v1.7
#
# Prerequisites:
#   - brew install create-dmg
#   - Developer ID certificate in Keychain (Developer ID Application: Potential, Inc.)
#   - Notarytool keychain profile "notary" configured
#   - Android SDK installed (for APK build)
#   - gh CLI installed (for uploading to GitHub)

set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <tag>"
  echo "Example: $0 v1.7"
  exit 1
fi

TAG="$1"
VERSION="${TAG#v}"
IDENTITY="Developer ID Application: Potential, Inc. (6Y24LA63S7)"

echo "Building release for $TAG (version $VERSION)..."

# Verify signing identity exists
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "ERROR: Developer ID certificate not found in Keychain."
  echo "Expected: $IDENTITY"
  echo "Run 'security find-identity -v -p codesigning' to see available identities."
  exit 1
fi

# Save current branch
CURRENT_BRANCH=$(git branch --show-current)

# Checkout tag
echo "Checking out $TAG..."
git checkout "$TAG"

# Build Mac binary
echo "Building Mac binary..."
swift build -c release

# Create .app bundle
echo "Creating .app bundle..."
APP_BUNDLE="build/Daylight Mirror.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp .build/release/DaylightMirror "$APP_BUNDLE/Contents/MacOS/DaylightMirror"

# Copy CLI binary if it exists
if [ -f ".build/release/daylight-mirror" ]; then
  cp .build/release/daylight-mirror "$APP_BUNDLE/Contents/MacOS/daylight-mirror"
fi

# Update Info.plist with correct version
sed "s/<string>1.0<\/string>/<string>$VERSION<\/string>/g" Info.plist > "$APP_BUNDLE/Contents/Info.plist"

cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Sign with Developer ID — each binary individually, then the bundle
echo "Signing with Developer ID..."
if [ -f "$APP_BUNDLE/Contents/MacOS/daylight-mirror" ]; then
  codesign -s "$IDENTITY" -f --options runtime --timestamp "$APP_BUNDLE/Contents/MacOS/daylight-mirror"
fi
codesign -s "$IDENTITY" -f --options runtime --timestamp "$APP_BUNDLE/Contents/MacOS/DaylightMirror"
codesign -s "$IDENTITY" -f --options runtime --timestamp "$APP_BUNDLE"

# Verify signature
echo "Verifying signature..."
codesign -dvv "$APP_BUNDLE"

# Create DMG
echo "Creating DMG..."
if command -v create-dmg &> /dev/null; then
  create-dmg \
    --volname "Daylight Mirror $VERSION" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "Daylight Mirror.app" 175 120 \
    --hide-extension "Daylight Mirror.app" \
    --app-drop-link 425 120 \
    "DaylightMirror-$TAG.dmg" \
    "$APP_BUNDLE" || {
      echo "create-dmg failed, falling back to hdiutil..."
      hdiutil create -volname "Daylight Mirror $VERSION" \
        -srcfolder "$APP_BUNDLE" \
        -ov -format UDZO \
        "DaylightMirror-$TAG.dmg"
    }
else
  echo "create-dmg not found, using hdiutil..."
  hdiutil create -volname "Daylight Mirror $VERSION" \
    -srcfolder "$APP_BUNDLE" \
    -ov -format UDZO \
    "DaylightMirror-$TAG.dmg"
fi

# Sign DMG
echo "Signing DMG..."
codesign -s "$IDENTITY" --timestamp "DaylightMirror-$TAG.dmg"

# Notarize
echo "Notarizing DMG..."
xcrun notarytool submit "DaylightMirror-$TAG.dmg" --keychain-profile "notary" --wait

# Staple
echo "Stapling notarization ticket..."
xcrun stapler staple "DaylightMirror-$TAG.dmg"

echo "Verifying notarization..."
spctl --assess -vvv --type open "DaylightMirror-$TAG.dmg"

# Build Android APK
echo "Building Android APK..."
cd android

# Update version in build.gradle.kts
sed -i.bak "s/versionName = \"1.0\"/versionName = \"$VERSION\"/" app/build.gradle.kts

./gradlew assembleDebug

# Restore original build.gradle.kts
mv app/build.gradle.kts.bak app/build.gradle.kts

cd ..

# Copy and rename APK
cp android/app/build/outputs/apk/debug/app-debug.apk "DaylightMirror-$TAG.apk"

echo ""
echo "Build complete!"
echo "  DMG: DaylightMirror-$TAG.dmg (signed + notarized)"
echo "  APK: DaylightMirror-$TAG.apk"
echo ""

# Upload to GitHub release
read -p "Upload to GitHub release $TAG? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo "Uploading to GitHub..."
  # Upload versioned names
  gh release upload "$TAG" "DaylightMirror-$TAG.dmg" "DaylightMirror-$TAG.apk"
  # Upload stable names for permanent download links
  cp "DaylightMirror-$TAG.dmg" DaylightMirror.dmg
  cp "DaylightMirror-$TAG.apk" DaylightMirror.apk
  gh release upload "$TAG" DaylightMirror.dmg DaylightMirror.apk
  rm DaylightMirror.dmg DaylightMirror.apk
  echo "Upload complete! Both versioned + stable names uploaded."
else
  echo "Skipping upload. To upload manually, run:"
  echo "  gh release upload $TAG DaylightMirror-$TAG.dmg DaylightMirror-$TAG.apk"
fi

# Return to original branch
echo "Returning to $CURRENT_BRANCH..."
git checkout "$CURRENT_BRANCH"

echo "Done!"
