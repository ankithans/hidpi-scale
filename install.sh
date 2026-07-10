#!/bin/zsh
# Build and install hidpi-scale: compiles the tools, registers the vdisplay
# daemon as a LaunchAgent (starts at login), and applies scaling immediately.
set -e
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

LABEL="com.hidpiscale"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if ! command -v displayplacer >/dev/null 2>&1; then
  echo "Installing displayplacer (Homebrew)..."
  brew install displayplacer
fi

echo "Building..."
clang -fobjc-arc -framework Foundation -framework CoreGraphics -framework IOKit -o vdisplay vdisplay.m
clang -fobjc-arc -framework Foundation -framework CoreGraphics -framework ColorSync -o mirror mirror.m
clang -fobjc-arc -framework Foundation -framework CoreGraphics -framework ColorSync -o lsmon lsmon.m
chmod +x set-scale.sh uninstall.sh

echo "Registering LaunchAgent..."
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PWD/vdisplay</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$PWD/vdisplay.log</string>
    <key>StandardErrorPath</key>
    <string>$PWD/vdisplay.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo ""
echo "Installed. Scaling applies automatically a few seconds after a monitor"
echo "listed in models.conf is connected (and at login). Change the size with:"
echo "  $PWD/set-scale.sh [native|small|medium|large]"
