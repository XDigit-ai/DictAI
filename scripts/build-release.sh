#!/bin/bash
# Build and package Talk for distribution
set -e

# Configuration
APP_NAME="DictAI"                 # PRODUCT_NAME in the Xcode project; the scheme is still Talk
ENTITLEMENTS="Talk/Talk/Talk-Pro.entitlements"  # same entitlements as the Debug build (adds Apple Events for agent mode)
SCHEME="DictAI"                   # shared scheme in Talk.xcodeproj
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="/tmp/TalkRelease"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/code/releases/DictAI}"  # outside iCloud: synced folders re-add xattrs and codesign rejects them
VERSION=$(date +%Y.%m.%d)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Building $APP_NAME for Distribution${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check for signing certificate (prefer Developer ID, fallback to Apple Development)
DEVELOPER_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')
APPLE_DEV=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | awk -F'"' '{print $2}')

if [ -n "$DEVELOPER_ID" ]; then
    echo -e "${GREEN}✓ Found Developer ID: $DEVELOPER_ID${NC}"
    SIGNING_IDENTITY="$DEVELOPER_ID"
    CAN_NOTARIZE=true
elif [ -n "$APPLE_DEV" ]; then
    echo -e "${YELLOW}⚠ No Developer ID, using Apple Development certificate${NC}"
    echo -e "${YELLOW}  Using: $APPLE_DEV${NC}"
    echo -e "${YELLOW}  (Works on your machine, recipients need to run: xattr -cr Talk.app)${NC}"
    SIGNING_IDENTITY="$APPLE_DEV"
    CAN_NOTARIZE=false
else
    echo -e "${YELLOW}⚠ No certificates found${NC}"
    echo -e "${YELLOW}  Using ad-hoc signing (recipients will need to run: xattr -cr Talk.app)${NC}"
    SIGNING_IDENTITY="-"
    CAN_NOTARIZE=false
fi
echo ""

# Hardened runtime enforces library validation: the app may only load frameworks
# signed by the same Team ID. Ad-hoc signatures have no Team ID, so an ad-hoc app
# with the hardened runtime cannot load whisper.framework and dies at launch.
# The hardened runtime only matters for notarization, so drop it for ad-hoc builds.
if [ "$SIGNING_IDENTITY" = "-" ]; then
    HARDENED_RUNTIME="NO"
    RUNTIME_FLAGS=()
else
    HARDENED_RUNTIME="YES"
    RUNTIME_FLAGS=(--options runtime --timestamp)
fi

# Clean previous builds
echo "Cleaning previous builds..."
rm -rf "$BUILD_DIR"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# Build Release
echo "Building Release configuration..."
cd "$PROJECT_DIR/Talk"
xcodebuild -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    CODE_SIGN_STYLE="Manual" \
    ENABLE_HARDENED_RUNTIME="$HARDENED_RUNTIME" \
    CODE_SIGN_ENTITLEMENTS="Talk/Talk-Pro.entitlements" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    build 2>&1 | grep -E "(error:|warning:|BUILD|Signing)" || true

if [ ! -d "$BUILD_DIR/Build/Products/Release/$APP_NAME.app" ]; then
    echo -e "${RED}✗ Build failed${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Build succeeded${NC}"
echo ""

# Copy app to output
APP_PATH="$OUTPUT_DIR/$APP_NAME.app"
cp -R "$BUILD_DIR/Build/Products/Release/$APP_NAME.app" "$APP_PATH"

# Remove ALL extended attributes (including Finder info and resource forks)
echo "Removing extended attributes and resource forks..."
# Remove resource fork files first
find "$APP_PATH" -name '._*' -delete 2>/dev/null || true
find "$APP_PATH" -name '.DS_Store' -delete 2>/dev/null || true
# Remove all xattrs from every file
find "$APP_PATH" -exec xattr -c {} \; 2>/dev/null || true
# Also use xattr -cr on the whole bundle
xattr -cr "$APP_PATH" 2>/dev/null || true
# Strip resource forks using dot_clean
dot_clean -m "$APP_PATH" 2>/dev/null || true

# Re-sign frameworks first, then the app
echo "Signing app..."

# COMPLETELY remove old signatures from frameworks first
WHISPER_FW="$APP_PATH/Contents/Frameworks/whisper.framework"
if [ -d "$WHISPER_FW" ]; then
    echo "  Removing old signature from whisper.framework..."
    # Remove signature from the binary
    codesign --remove-signature "$WHISPER_FW/Versions/A/whisper" 2>/dev/null || true
    codesign --remove-signature "$WHISPER_FW" 2>/dev/null || true
    # Now re-sign with our identity
    echo "  Re-signing whisper.framework..."
    codesign --force "${RUNTIME_FLAGS[@]}" --sign "$SIGNING_IDENTITY" "$WHISPER_FW/Versions/A/whisper"
    codesign --force "${RUNTIME_FLAGS[@]}" --sign "$SIGNING_IDENTITY" "$WHISPER_FW"
fi

# Sign any other frameworks/dylibs
find "$APP_PATH/Contents/Frameworks" -type f -name "*.dylib" 2>/dev/null | while read fw; do
    codesign --remove-signature "$fw" 2>/dev/null || true
    codesign --force "${RUNTIME_FLAGS[@]}" --sign "$SIGNING_IDENTITY" "$fw" 2>/dev/null || true
done

# Sign the main app bundle
echo "  Signing main app..."
codesign --force --sign "$SIGNING_IDENTITY" \
    "${RUNTIME_FLAGS[@]}" \
    --entitlements "$PROJECT_DIR/$ENTITLEMENTS" \
    "$APP_PATH"

# Verify signature
echo "Verifying signature..."
if codesign --verify --verbose "$APP_PATH" 2>/dev/null; then
    echo -e "${GREEN}✓ Signature valid${NC}"
else
    echo -e "${YELLOW}⚠ Ad-hoc signature (expected for non-Developer ID)${NC}"
fi
echo ""

# Create professional DMG with nice layout
echo "Creating DMG..."
DMG_NAME="$APP_NAME-$VERSION"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME.dmg"

# Remove old DMG
rm -f "$DMG_PATH"

# Check if create-dmg is available
if command -v create-dmg &> /dev/null; then
    echo "Using create-dmg for professional layout..."
    create-dmg \
        --volname "$APP_NAME" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "$APP_NAME.app" 150 190 \
        --app-drop-link 450 190 \
        --hide-extension "$APP_NAME.app" \
        --no-internet-enable \
        "$DMG_PATH" \
        "$APP_PATH" 2>/dev/null || {
            # Fallback if create-dmg fails
            echo "create-dmg failed, using fallback method..."
            STAGING_DIR="/tmp/$APP_NAME-staging"
            rm -rf "$STAGING_DIR"
            mkdir -p "$STAGING_DIR"
            cp -R "$APP_PATH" "$STAGING_DIR/"
            ln -s /Applications "$STAGING_DIR/Applications"
            hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH" -quiet
            rm -rf "$STAGING_DIR"
        }
else
    # Fallback to simple DMG
    echo "create-dmg not found, using simple layout..."
    STAGING_DIR="/tmp/$APP_NAME-staging"
    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_DIR"
    cp -R "$APP_PATH" "$STAGING_DIR/"
    ln -s /Applications "$STAGING_DIR/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH" -quiet
    rm -rf "$STAGING_DIR"
fi

echo -e "${GREEN}✓ DMG created: $DMG_PATH${NC}"
echo ""

# Also create a ZIP
echo "Creating ZIP..."
ZIP_PATH="$OUTPUT_DIR/$DMG_NAME.zip"
cd "$OUTPUT_DIR"
zip -r -q "$ZIP_PATH" "$APP_NAME.app"
echo -e "${GREEN}✓ ZIP created: $ZIP_PATH${NC}"
echo ""

# Notarization (if Developer ID available)
if [ "$CAN_NOTARIZE" = true ]; then
    echo -e "${YELLOW}To notarize the app, run:${NC}"
    echo "  xcrun notarytool submit '$DMG_PATH' --keychain-profile 'AC_PASSWORD' --wait"
    echo "  xcrun stapler staple '$DMG_PATH'"
    echo ""
fi

# Summary
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Distribution Package Ready${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Output files:"
echo "  • $APP_PATH"
echo "  • $DMG_PATH"
echo "  • $ZIP_PATH"
echo ""

if [ "$CAN_NOTARIZE" = false ]; then
    echo -e "${YELLOW}Note: This build is ad-hoc signed.${NC}"
    echo -e "${YELLOW}Recipients should run before opening:${NC}"
    echo -e "${YELLOW}  xattr -cr Talk.app${NC}"
    echo ""
fi

# File sizes
echo "File sizes:"
APP_SIZE=$(du -sh "$APP_PATH" | awk '{print $1}')
DMG_SIZE=$(du -h "$DMG_PATH" | awk '{print $1}')
ZIP_SIZE=$(du -h "$ZIP_PATH" | awk '{print $1}')
echo "  • App: $APP_SIZE"
echo "  • DMG: $DMG_SIZE"
echo "  • ZIP: $ZIP_SIZE"
echo ""

echo -e "${GREEN}Done!${NC}"
