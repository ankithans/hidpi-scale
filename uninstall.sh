#!/bin/zsh
# Remove the hidpi-scale LaunchAgent and stop the daemon. The virtual displays
# disappear with it and the monitor returns to its normal modes.
LABEL="com.hidpiscale"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
echo "Uninstalled. Delete this directory to remove everything."
