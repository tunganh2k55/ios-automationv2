#!/bin/bash
set -e

# Build daemon/app/tweak on Mac via SSH
# Usage: ./scripts/build-ssh.sh [daemon|app|tweak|all]

MAC_HOST="${MAC_HOST:-192.168.1.53}"
MAC_USER="${MAC_USER:-admin}"
MAC_PORT="${MAC_PORT:-22}"
THEOS="${THEOS:-~/theos}"
REMOTE_DIR="${REMOTE_DIR:-~/ios-auto}"

TARGET="${1:-all}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Build iOS automation on Mac ($MAC_HOST) ==="
echo "Target: $TARGET"
echo ""

# Create output directory
mkdir -p "$PROJECT_DIR/out"

# SSH command helper
ssh_cmd() {
    ssh -p "$MAC_PORT" "$MAC_USER@$MAC_HOST" "$@"
}

# Upload source to Mac
upload_source() {
    echo ">> Uploading source to Mac..."
    ssh_cmd "mkdir -p $REMOTE_DIR"

    # Upload daemon
    if [ "$TARGET" = "all" ] || [ "$TARGET" = "daemon" ]; then
        echo "   - daemon/"
        scp -P "$MAC_PORT" -r "$PROJECT_DIR/app/daemon" "$MAC_USER@$MAC_HOST:$REMOTE_DIR/app/"
        scp -P "$MAC_PORT" -r "$PROJECT_DIR/app/web" "$MAC_USER@$MAC_HOST:$REMOTE_DIR/app/"
    fi

    # Upload app
    if [ "$TARGET" = "all" ] || [ "$TARGET" = "app" ]; then
        echo "   - app/"
        scp -P "$MAC_PORT" -r "$PROJECT_DIR/app/app" "$MAC_USER@$MAC_HOST:$REMOTE_DIR/app/"
    fi

    # Upload tweak
    if [ "$TARGET" = "all" ] || [ "$TARGET" = "tweak" ]; then
        echo "   - tweak/"
        scp -P "$MAC_PORT" -r "$PROJECT_DIR/app/tweak" "$MAC_USER@$MAC_HOST:$REMOTE_DIR/app/"
    fi

    # Upload dist (control file)
    scp -P "$MAC_PORT" -r "$PROJECT_DIR/app/dist" "$MAC_USER@$MAC_HOST:$REMOTE_DIR/app/"
    scp -P "$MAC_PORT" -r "$PROJECT_DIR/app/repo" "$MAC_USER@$MAC_HOST:$REMOTE_DIR/app/"
}

# Build on Mac
build_component() {
    local component=$1
    echo ">> Building $component..."
    ssh_cmd "cd $REMOTE_DIR/app/$component && export THEOS=$THEOS && make clean && make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless"
}

# Download .deb files
download_debs() {
    echo ">> Downloading .deb files..."
    scp -P "$MAC_PORT" "$MAC_USER@$MAC_HOST:$REMOTE_DIR/app/daemon/packages/*.deb" "$PROJECT_DIR/out/" 2>/dev/null || true
    scp -P "$MAC_PORT" "$MAC_USER@$MAC_HOST:$REMOTE_DIR/app/app/packages/*.deb" "$PROJECT_DIR/out/" 2>/dev/null || true
    scp -P "$MAC_PORT" "$MAC_USER@$MAC_HOST:$REMOTE_DIR/app/tweak/packages/*.deb" "$PROJECT_DIR/out/" 2>/dev/null || true
}

# Merge debs
merge_debs() {
    echo ">> Merging .deb files..."
    mkdir -p "$PROJECT_DIR/out_merged"
    python "$PROJECT_DIR/app/repo/merge_deb.py" "$PROJECT_DIR/out" "$PROJECT_DIR/out_merged"
}

# Main
upload_source

if [ "$TARGET" = "all" ]; then
    build_component "daemon"
    build_component "app"
    build_component "tweak"
elif [ "$TARGET" = "daemon" ] || [ "$TARGET" = "app" ] || [ "$TARGET" = "tweak" ]; then
    build_component "$TARGET"
else
    echo "Unknown target: $TARGET"
    exit 1
fi

download_debs
merge_debs

echo ""
echo "=== Build complete ==="
echo "Output: $PROJECT_DIR/out_merged/"
ls -la "$PROJECT_DIR/out_merged/"
