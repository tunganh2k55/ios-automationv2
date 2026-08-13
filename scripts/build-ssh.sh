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

# Đồng bộ version app (Info.plist) theo app/dist/control — GIỐNG bước "Sync app version"
# trong CI (build.yml). Thiếu bước này thì make package copy nguyên Info.plist nguồn (0.7.4)
# vào bundle → app hiện sai version dù Control gói là 1.0.x. Phải chạy TRƯỚC khi build app.
sync_app_version() {
    echo ">> Sync app version (Info.plist) theo dist/control..."
    ssh_cmd "VER=\$(awk -F': ' '/^Version:/{print \$2; exit}' $REMOTE_DIR/app/dist/control); \
        echo \"   app CFBundleShortVersionString -> \$VER\"; \
        /usr/libexec/PlistBuddy -c \"Set :CFBundleShortVersionString \$VER\" $REMOTE_DIR/app/app/Resources/Info.plist; \
        /usr/libexec/PlistBuddy -c \"Set :CFBundleVersion \$VER\" $REMOTE_DIR/app/app/Resources/Info.plist"
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
    sync_app_version          # đồng bộ version TRƯỚC khi build app
    build_component "app"
    build_component "tweak"
elif [ "$TARGET" = "daemon" ] || [ "$TARGET" = "app" ] || [ "$TARGET" = "tweak" ]; then
    [ "$TARGET" = "app" ] && sync_app_version
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
