#!/bin/bash
# Builds the download: build/NotchAgent-<version>.dmg, a disk image with the
# app and an Applications shortcut to drag it onto.
#
# Signed ad hoc, not with your development certificate: that one carries
# your Apple ID's email, and it isn't trusted on other Macs anyway. So the
# first open needs System Settings › Privacy & Security › Open Anyway
# until the app is signed with a Developer ID and notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY=- ./scripts/build-app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" packaging/Info.plist)
DMG="build/NotchAgent-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R build/NotchAgent.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Notch Agent" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
