#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_NAME="Run Overlay"
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"

rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"

swiftc \
    "$ROOT_DIR"/Sources/RunningDataOverlay/*.swift \
    -parse-as-library \
    -o "$CONTENTS_DIR/MacOS/$APP_NAME"

cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
print -n 'APPL????' > "$CONTENTS_DIR/PkgInfo"
codesign --force --sign - "$APP_BUNDLE"

print "Built $APP_BUNDLE"
