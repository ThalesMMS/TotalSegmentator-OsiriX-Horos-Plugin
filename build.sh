#!/bin/bash
set -e

# Build TotalSegmentatorHorosPlugin for Horos and/or OsiriX
# Usage: ./build.sh [horos|osirix|both] [--sign]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/MyOsiriXPluginFolder-Swift"
PROJECT="$PROJECT_DIR/TotalSegmentatorHorosPlugin.xcodeproj"
SCHEME="TotalSegmentatorHorosPlugin"
BUILD_DIR="$PROJECT_DIR/build"
RELEASES_DIR="$SCRIPT_DIR/Releases"
DATE=$(date +"%Y %m %d")
TMP_BASE="${TMPDIR:-/tmp/}"
RESTORE_DIR="$(mktemp -d "${TMP_BASE%/}/totalsegmentator-plugin-build.XXXXXX")"
PROJECT_BACKUP="$RESTORE_DIR/project.pbxproj"
BRIDGING_HEADER="TotalSegmentatorHorosPlugin-Bridging-Header.h"
BRIDGING_HEADER_BACKUP="$RESTORE_DIR/$BRIDGING_HEADER"

cp "$PROJECT/project.pbxproj" "$PROJECT_BACKUP"
cp "$PROJECT_DIR/$BRIDGING_HEADER" "$BRIDGING_HEADER_BACKUP"

restore_configuration() {
    if [[ -d "$RESTORE_DIR" ]]; then
        echo ""
        echo "==> Restoring original configuration..."
        cp "$PROJECT_BACKUP" "$PROJECT/project.pbxproj"
        cp "$BRIDGING_HEADER_BACKUP" "$PROJECT_DIR/$BRIDGING_HEADER"
        rm -rf "$RESTORE_DIR"
    fi
}

trap restore_configuration EXIT

# Parse arguments
PLATFORM="${1:-both}"
SIGN=false
if [[ "$1" == "--sign" ]]; then
    PLATFORM="both"
    SIGN=true
elif [[ "$2" == "--sign" ]]; then
    SIGN=true
fi

# Validate platform argument
if [[ "$PLATFORM" != "horos" && "$PLATFORM" != "osirix" && "$PLATFORM" != "both" ]]; then
    echo "Usage: ./build.sh [horos|osirix|both] [--sign]"
    echo "  horos   - Build for Horos only"
    echo "  osirix  - Build for OsiriX only"
    echo "  both    - Build for both platforms (default)"
    echo "  --sign  - Ad-hoc sign the plugins"
    exit 1
fi

build_platform() {
    local PLAT="$1"
    local PLAT_UPPER=$(echo "$PLAT" | tr '[:lower:]' '[:upper:]')
    # Capitalize first letter: horos -> Horos, osirix -> Osirix
    local PLAT_CAPITALIZED="$(tr '[:lower:]' '[:upper:]' <<< ${PLAT:0:1})${PLAT:1}"

    echo ""
    echo "========================================"
    echo "Building for $PLAT_UPPER"
    echo "========================================"

    # Switch to platform-specific configuration
    echo "==> Switching to $PLAT configuration..."
    cp "$PROJECT/project_${PLAT_CAPITALIZED}.pbxproj" "$PROJECT/project.pbxproj"
    cp "$PROJECT_DIR/TotalSegmentatorHorosPlugin-Bridging-Header_${PLAT_CAPITALIZED}.h" \
       "$PROJECT_DIR/$BRIDGING_HEADER"

    # Clean previous build
    echo "==> Cleaning previous build..."
    rm -rf "$BUILD_DIR"

    # Build
    echo "==> Building $SCHEME (Release) for $PLAT_UPPER..."
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        CONFIGURATION_BUILD_DIR="$BUILD_DIR/Release" \
        build

    BUILT_PLUGIN="$BUILD_DIR/Release/TotalSegmentatorHorosPlugin.osirixplugin"

    if [[ ! -d "$BUILT_PLUGIN" ]]; then
        echo "ERROR: Build failed - plugin not found at $BUILT_PLUGIN"
        exit 1
    fi

    echo "==> Build successful!"

    # Create platform-specific releases directory
    local PLAT_RELEASES_DIR="$RELEASES_DIR/$PLAT_CAPITALIZED"
    mkdir -p "$PLAT_RELEASES_DIR"

    # Copy plugin
    local DEST="$PLAT_RELEASES_DIR/TotalSegmentatorPlugin $DATE.osirixplugin"
    echo "==> Creating plugin: $DEST"
    rm -rf "$DEST"
    cp -R "$BUILT_PLUGIN" "$DEST"

    # Sign if requested
    if $SIGN; then
        echo "==> Signing plugin..."
        codesign --force --deep --sign - "$DEST"
        echo "==> Plugin signed (ad-hoc)"
    fi

    echo "==> $PLAT_UPPER build complete: $DEST"
}

# Build for selected platform(s)
if [[ "$PLATFORM" == "horos" || "$PLATFORM" == "both" ]]; then
    build_platform "horos"
fi

if [[ "$PLATFORM" == "osirix" || "$PLATFORM" == "both" ]]; then
    build_platform "osirix"
fi

# Restore the configuration that was active before the build.
restore_configuration

echo ""
echo "========================================"
echo "Build complete!"
echo "========================================"
echo ""
echo "Plugins created in:"
if [[ "$PLATFORM" == "horos" || "$PLATFORM" == "both" ]]; then
    echo "  Horos:  $RELEASES_DIR/Horos/"
fi
if [[ "$PLATFORM" == "osirix" || "$PLATFORM" == "both" ]]; then
    echo "  OsiriX: $RELEASES_DIR/Osirix/"
fi
echo ""
echo "To install, copy the .osirixplugin to:"
echo "  Horos:  ~/Library/Application Support/Horos/Plugins/"
echo "  OsiriX: ~/Library/Application Support/OsiriX/Plugins/"
