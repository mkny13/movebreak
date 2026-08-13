#!/bin/bash
#
# Builds MoveBreak.app.
#
# Compiles with swiftc directly rather than SwiftPM: the SwiftPM manifest API shipped in
# this machine's CommandLineTools is broken (libPackageDescription.dylib is out of sync
# with its .swiftmodule and exports none of the expected symbols), so `swift build` cannot
# even parse a Package.swift. swiftc itself is fine.
#
# Usage:
#   ./scripts/build_app.sh                        # ad-hoc signature
#   ./scripts/build_app.sh "MoveBreak Signing"    # stable self-signed identity
#
# Pass an identity if you want the Automation (Apple Events) permission to survive
# rebuilds. TCC keys the grant to the code signature, and an ad-hoc signature changes
# every time the binary changes, so Chrome re-prompts after each build. See README.

set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY="${1:--}"
APP="MoveBreak.app"
DEPLOY_TARGET="arm64-apple-macosx14.4"

echo "==> Compiling"
mkdir -p build
swiftc -O \
    -sdk "$(xcrun --show-sdk-path)" \
    -target "$DEPLOY_TARGET" \
    -framework AppKit \
    -framework SwiftUI \
    -framework CoreAudio \
    -o build/MoveBreak \
    Sources/MoveBreak/*.swift

echo "==> Running self-test"
./build/MoveBreak --self-test > /dev/null || {
    echo "self-test FAILED — run ./build/MoveBreak --self-test to see which cases" >&2
    exit 1
}

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/MoveBreak "$APP/Contents/MacOS/MoveBreak"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "==> Signing (identity: $IDENTITY)"
codesign --force --sign "$IDENTITY" "$APP"

if [ "$IDENTITY" = "-" ]; then
    echo
    echo "    Note: ad-hoc signed. Chrome will re-ask for Automation permission after"
    echo "    every rebuild. See README for the one-time stable-identity setup."
fi

echo
echo "Built $APP"
echo "  open ./$APP                     launch it"
echo "  ./build/MoveBreak --diagnose    watch detection live"
