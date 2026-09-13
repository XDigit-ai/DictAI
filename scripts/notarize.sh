#!/bin/bash
# Notarize Talk for distribution
# Requires: Developer ID certificate and app-specific password stored in keychain
#
# Setup (one-time):
# 1. Get Developer ID Application certificate from developer.apple.com
# 2. Create app-specific password at appleid.apple.com
# 3. Store it: xcrun notarytool store-credentials "AC_PASSWORD" \
#              --apple-id "your@email.com" \
#              --team-id "YOUR_TEAM_ID" \
#              --password "xxxx-xxxx-xxxx-xxxx"

set -e

# Configuration
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${OUTPUT_DIR:-$HOME/code/releases/DictAI}"  # must match build-release.sh
KEYCHAIN_PROFILE="AC_PASSWORD"  # Name used when storing credentials

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Find the DMG
DMG=$(ls -t "$DIST_DIR"/*.dmg 2>/dev/null | head -1)

if [ -z "$DMG" ]; then
    echo -e "${RED}No DMG found in $DIST_DIR${NC}"
    echo "Run build-release.sh first."
    exit 1
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Notarizing: $(basename "$DMG")${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check for Developer ID
DEVELOPER_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')

if [ -z "$DEVELOPER_ID" ]; then
    echo -e "${RED}✗ No Developer ID certificate found${NC}"
    echo ""
    echo "To get a Developer ID certificate:"
    echo "1. Join Apple Developer Program (\$99/year): https://developer.apple.com/programs/"
    echo "2. Create a Developer ID Application certificate in Xcode or developer.apple.com"
    echo "3. Download and install the certificate"
    exit 1
fi

echo -e "${GREEN}✓ Using: $DEVELOPER_ID${NC}"
echo ""

# Submit for notarization
echo "Submitting for notarization (this may take several minutes)..."
xcrun notarytool submit "$DMG" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

# Check result
if [ $? -eq 0 ]; then
    echo ""
    echo "Stapling notarization ticket..."
    xcrun stapler staple "$DMG"

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Notarization Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "Your DMG is now notarized and can be distributed."
    echo "Users will be able to open it without Gatekeeper warnings."
    echo ""
    echo "File: $DMG"
else
    echo ""
    echo -e "${RED}Notarization failed${NC}"
    echo "Check the Apple Developer portal for more details."
    exit 1
fi
