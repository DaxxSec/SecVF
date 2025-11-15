#!/bin/bash

# SecVF Release Build Script
# Creates a shareable .app bundle with optional version increment

set -e

PROJECT_DIR="/Users/stephstewart/Code/Sandboxes/SecVF"
PROJECT_FILE="$PROJECT_DIR/SecVF.xcodeproj"
SCHEME="SecVF"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/SecVF.xcarchive"
EXPORT_PATH="$BUILD_DIR/Release"

cd "$PROJECT_DIR"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║         SecVF Release Build Script                      ║"
echo "║         Computer Security Incident Response Team          ║"
echo "║         Virtualization Framework                          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Get current version
CURRENT_VERSION=$(xcodebuild -project "$PROJECT_FILE" -showBuildSettings | grep MARKETING_VERSION | awk '{print $3}' | head -1)
CURRENT_BUILD=$(xcodebuild -project "$PROJECT_FILE" -showBuildSettings | grep CURRENT_PROJECT_VERSION | awk '{print $3}' | head -1 | grep -v IPHONEOS)

echo "Current Version: $CURRENT_VERSION (Build $CURRENT_BUILD)"
echo ""

# Prompt for version increment
echo "Do you want to increment the version?"
echo "  1) Increment Major (1.0.0 -> 2.0.0)"
echo "  2) Increment Minor (1.0.0 -> 1.1.0)"
echo "  3) Increment Patch (1.0.0 -> 1.0.1)"
echo "  4) Increment Build Only"
echo "  5) Skip (keep current version - for testing)"
echo ""
read -p "Select option [1-5]: " VERSION_CHOICE

NEW_VERSION=$CURRENT_VERSION
NEW_BUILD=$CURRENT_BUILD

case $VERSION_CHOICE in
    1)
        # Major version increment
        MAJOR=$(echo $CURRENT_VERSION | cut -d. -f1)
        MAJOR=$((MAJOR + 1))
        NEW_VERSION="$MAJOR.0.0"
        NEW_BUILD=1
        echo "→ New version: $NEW_VERSION (Build $NEW_BUILD)"
        ;;
    2)
        # Minor version increment
        MAJOR=$(echo $CURRENT_VERSION | cut -d. -f1)
        MINOR=$(echo $CURRENT_VERSION | cut -d. -f2)
        MINOR=$((MINOR + 1))
        NEW_VERSION="$MAJOR.$MINOR.0"
        NEW_BUILD=1
        echo "→ New version: $NEW_VERSION (Build $NEW_BUILD)"
        ;;
    3)
        # Patch version increment
        MAJOR=$(echo $CURRENT_VERSION | cut -d. -f1)
        MINOR=$(echo $CURRENT_VERSION | cut -d. -f2)
        PATCH=$(echo $CURRENT_VERSION | cut -d. -f3)
        PATCH=$((PATCH + 1))
        NEW_VERSION="$MAJOR.$MINOR.$PATCH"
        NEW_BUILD=1
        echo "→ New version: $NEW_VERSION (Build $NEW_BUILD)"
        ;;
    4)
        # Build number only
        NEW_BUILD=$((CURRENT_BUILD + 1))
        echo "→ New version: $NEW_VERSION (Build $NEW_BUILD)"
        ;;
    5)
        echo "→ Keeping current version: $NEW_VERSION (Build $NEW_BUILD)"
        ;;
    *)
        echo "Invalid option. Exiting."
        exit 1
        ;;
esac

# Update version numbers in project if changed
if [ "$NEW_VERSION" != "$CURRENT_VERSION" ] || [ "$NEW_BUILD" != "$CURRENT_BUILD" ]; then
    echo ""
    echo "Updating version in Xcode project..."

    # Update MARKETING_VERSION
    /usr/libexec/PlistBuddy -c "Set :objects:4D97F3292C8E5A5D00E1234A:buildSettings:MARKETING_VERSION $NEW_VERSION" "$PROJECT_FILE/project.pbxproj" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :objects:4D97F3432C8E5A5D00E1234A:buildSettings:MARKETING_VERSION $NEW_VERSION" "$PROJECT_FILE/project.pbxproj" 2>/dev/null || true

    # Update CURRENT_PROJECT_VERSION
    /usr/libexec/PlistBuddy -c "Set :objects:4D97F3292C8E5A5D00E1234A:buildSettings:CURRENT_PROJECT_VERSION $NEW_BUILD" "$PROJECT_FILE/project.pbxproj" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :objects:4D97F3432C8E5A5D00E1234A:buildSettings:CURRENT_PROJECT_VERSION $NEW_BUILD" "$PROJECT_FILE/project.pbxproj" 2>/dev/null || true

    # Use agvtool as fallback
    xcrun agvtool new-marketing-version "$NEW_VERSION" 2>/dev/null || echo "  (Using project.pbxproj direct edit)"
    xcrun agvtool new-version -all "$NEW_BUILD" 2>/dev/null || echo "  (Using project.pbxproj direct edit)"

    echo "✓ Version updated"
fi

echo ""
echo "Building Release version..."
echo ""

# Clean previous builds
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build the project
echo "→ Compiling..."
xcodebuild clean build \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    | grep -E "Build succeeded|error:" || true

# Check if build succeeded
if [ ! -d "$BUILD_DIR/DerivedData/Build/Products/Release/SecVF.app" ]; then
    echo ""
    echo "❌ Build failed!"
    exit 1
fi

echo ""
echo "✓ Build succeeded!"

# Copy app to release folder
echo ""
echo "Creating distributable package..."
mkdir -p "$EXPORT_PATH"
cp -R "$BUILD_DIR/DerivedData/Build/Products/Release/SecVF.app" "$EXPORT_PATH/"

# Create a DMG (optional)
echo "→ Creating DMG image..."
DMG_PATH="$EXPORT_PATH/SecVF-v${NEW_VERSION}-build${NEW_BUILD}.dmg"
hdiutil create -volname "SecVF v${NEW_VERSION}" -srcfolder "$EXPORT_PATH/SecVF.app" -ov -format UDZO "$DMG_PATH" 2>/dev/null || echo "  (DMG creation skipped)"

# Create ZIP archive
echo "→ Creating ZIP archive..."
cd "$EXPORT_PATH"
ZIP_NAME="SecVF-v${NEW_VERSION}-build${NEW_BUILD}.zip"
zip -r -q "$ZIP_NAME" "SecVF.app"
cd "$PROJECT_DIR"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                  BUILD COMPLETE! ✓                        ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Version: $NEW_VERSION (Build $NEW_BUILD)"
echo ""
echo "Shareable files created:"
echo "  📦 App Bundle:  $EXPORT_PATH/SecVF.app"
echo "  📦 ZIP:         $EXPORT_PATH/$ZIP_NAME"
if [ -f "$DMG_PATH" ]; then
    echo "  📦 DMG:         $DMG_PATH"
fi
echo ""
echo "You can share the ZIP or DMG file with others."
echo ""
