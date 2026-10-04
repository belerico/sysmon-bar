#!/bin/sh
# Build SysMon.app into ~/Applications and start it at login via a LaunchAgent.
# Usage: ./install.sh            build, install, (re)start
#        ./install.sh uninstall  stop and remove the app and the LaunchAgent
set -eu
cd "$(dirname "$0")"

APP="$HOME/Applications/SysMon.app"
LABEL="com.belerico.sysmon"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x SysMon 2>/dev/null || true

if [ "${1:-}" = "uninstall" ]; then
    rm -rf "$APP" "$AGENT"
    echo "Removed $APP and $AGENT"
    exit 0
fi

mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -parse-as-library -module-name SysMon -target "$(uname -m)-apple-macos14" \
    ./*.swift -o "$APP/Contents/MacOS/SysMon"
codesign --force --sign - "$APP"

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP/Contents/MacOS/SysMon</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "Installed $APP (starts at login)"
