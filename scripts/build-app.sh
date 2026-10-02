#!/bin/bash
# Builds NotchAgent.app into build/. With "install", also copies it to
# /Applications (or ~/Applications) and starts it.
#
# Signs with your Apple Development / Developer ID certificate when there is
# one, so macOS remembers the app's permissions across rebuilds; otherwise
# signs ad hoc. Override with SIGN_IDENTITY=<hash or name>.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/NotchAgent.app
swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NotchAgent "$APP/Contents/MacOS/"
cp packaging/Info.plist "$APP/Contents/"
[ -f build/AppIcon.icns ] || swift scripts/make-icon.swift build
cp build/AppIcon.icns "$APP/Contents/Resources/"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Developer ID Application|Apple Development/ { print $2; exit }')}"
codesign --force --sign "${IDENTITY:--}" --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad hoc})"

if [ "${1:-}" = "install" ]; then
    DEST=/Applications
    [ -w "$DEST" ] || DEST="$HOME/Applications"
    mkdir -p "$DEST"
    pkill -x NotchAgent 2>/dev/null && sleep 1 || true
    rm -rf "$DEST/NotchAgent.app"
    cp -R "$APP" "$DEST/"
    open "$DEST/NotchAgent.app"
    echo "Installed and started $DEST/NotchAgent.app"
fi
