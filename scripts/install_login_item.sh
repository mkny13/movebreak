#!/bin/bash
#
# Installs MoveBreak as a login item via a LaunchAgent.
#
# Uses a LaunchAgent rather than SMAppService because SMAppService.mainApp.register()
# is unreliable for locally-built, non-notarized bundles. A LaunchAgent pointing straight
# at the binary always works.
#
# Usage:
#   ./scripts/install_login_item.sh              # install and start
#   ./scripts/install_login_item.sh --uninstall  # stop and remove

set -euo pipefail

cd "$(dirname "$0")/.."

LABEL="com.mike.movebreak"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_BINARY="$(pwd)/MoveBreak.app/Contents/MacOS/MoveBreak"

if [ "${1:-}" = "--uninstall" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Removed login item."
    exit 0
fi

if [ ! -x "$APP_BINARY" ]; then
    echo "error: $APP_BINARY not found. Run ./scripts/build_app.sh first." >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_BINARY</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
PLIST_EOF

# bootout first so re-running picks up a changed path without a stale registration.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Installed login item: $PLIST"
echo "MoveBreak will start automatically at login (and is running now)."
