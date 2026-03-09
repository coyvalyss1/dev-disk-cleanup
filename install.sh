#!/bin/bash
# Install dev-disk-cleanup with automatic scheduling via launchd
# Runs weekly + checks on login if space is low

set -e

SCRIPT_NAME="dev-disk-cleanup.sh"
INSTALL_DIR="$HOME/.dev-disk-cleanup"
PLIST_PATH="$HOME/Library/LaunchAgents/com.dev-disk-cleanup.plist"

echo "🧹 Installing dev-disk-cleanup..."
echo ""

# Create install directory
mkdir -p "$INSTALL_DIR"

# Copy the cleanup script
if [ -f "$SCRIPT_NAME" ]; then
  cp "$SCRIPT_NAME" "$INSTALL_DIR/"
  chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
  echo "✅ Installed script to: $INSTALL_DIR/$SCRIPT_NAME"
else
  echo "❌ Error: $SCRIPT_NAME not found in current directory"
  exit 1
fi

# Create launchd plist for automatic scheduling
cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.dev-disk-cleanup</string>
  
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_DIR/$SCRIPT_NAME</string>
  </array>
  
  <key>StartInterval</key>
  <integer>604800</integer>
  
  <key>RunAtLoad</key>
  <true/>
  
  <key>StandardOutPath</key>
  <string>$INSTALL_DIR/stdout.log</string>
  
  <key>StandardErrorPath</key>
  <string>$INSTALL_DIR/stderr.log</string>
</dict>
</plist>
EOF

echo "✅ Created launchd plist: $PLIST_PATH"
echo ""

# Load the launchd agent
launchctl unload "$PLIST_PATH" 2>/dev/null || true
if launchctl load "$PLIST_PATH"; then
  echo "✅ Automatic disk cleanup enabled!"
  echo ""
  echo "📋 Configuration:"
  echo "  • Runs every 7 days (light cache cleanup)"
  echo "  • Checks on login (full cleanup if below 50 GB free)"
  echo "  • Keeps recent builds (modified within 14 days)"
  echo "  • Logs: $INSTALL_DIR/cleanup.log"
  echo ""
  echo "🔧 Manual Commands:"
  echo "  Preview what would be cleaned:"
  echo "    ~/.dev-disk-cleanup/dev-disk-cleanup.sh --dry-run"
  echo ""
  echo "  Force cleanup now:"
  echo "    ~/.dev-disk-cleanup/dev-disk-cleanup.sh --force"
  echo ""
  echo "  Check status:"
  echo "    launchctl list | grep dev-disk-cleanup"
  echo ""
  echo "  View logs:"
  echo "    tail -f ~/.dev-disk-cleanup/cleanup.log"
  echo ""
  echo "  Disable automatic cleanup:"
  echo "    launchctl unload ~/Library/LaunchAgents/com.dev-disk-cleanup.plist"
  echo ""
  echo "✅ Installation complete!"
else
  echo "❌ Failed to load launchd agent"
  echo ""
  echo "You can still run manual cleanups:"
  echo "  ~/.dev-disk-cleanup/dev-disk-cleanup.sh"
  exit 1
fi
