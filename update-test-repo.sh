#!/bin/bash
# Download latest build artifact vào web-license/test-repo/
# Dùng: ./update-test-repo.sh

set -e
cd "$(dirname "$0")"

echo "Downloading latest iosauto-repo artifact..."
rm -rf web-license/test-repo/debs
gh run download --repo tunganh2k55/ios-automationv2 -n iosauto-repo -D web-license/test-repo --clobber

echo "Done. Version:"
awk '/^Version:/{print $2}' web-license/test-repo/Packages
