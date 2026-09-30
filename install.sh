#!/bin/bash
# Install dev-disk-cleanup with a daily launchd job.
#
# Works from a clone (./install.sh) or piped from curl, in which case the files
# are downloaded from GitHub. Safe to re-run; an existing config is never replaced.

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/coyvalyss1/dev-disk-cleanup/main"
INSTALL_DIR="$HOME/.dev-disk-cleanup"
CONFIG_FILE="$HOME/.config/dev-disk-cleanup/config.sh"
LOG_DIR="$HOME/Library/Logs/dev-disk-cleanup"
LABEL="com.dev-disk-cleanup"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
FILES=(dev-disk-cleanup.sh config.example.sh skills/disk-cleanup/SKILL.md)

SOURCE_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/dev-disk-cleanup.sh" ]; then
  SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

echo "Installing dev-disk-cleanup to $INSTALL_DIR"
for f in "${FILES[@]}"; do
  mkdir -p "$INSTALL_DIR/$(dirname "$f")"
  if [ -n "$SOURCE_DIR" ]; then
    cp "$SOURCE_DIR/$f" "$INSTALL_DIR/$f"
  else
    curl -fsSL "$REPO_RAW/$f" -o "$INSTALL_DIR/$f"
  fi
done
chmod +x "$INSTALL_DIR/dev-disk-cleanup.sh"

if [ -f "$CONFIG_FILE" ]; then
  echo "Keeping existing config: $CONFIG_FILE"
else
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cp "$INSTALL_DIR/config.example.sh" "$CONFIG_FILE"
  echo "Created config: $CONFIG_FILE"
fi

# Offer the skill to AI coding CLIs that are present.
for skills_dir in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
  [ -d "$(dirname "$skills_dir")" ] || continue
  mkdir -p "$skills_dir"
  if [ -e "$skills_dir/disk-cleanup" ] && [ ! -L "$skills_dir/disk-cleanup" ]; then
    echo "Skipping $skills_dir/disk-cleanup (already exists)"
  else
    ln -sfn "$INSTALL_DIR/skills/disk-cleanup" "$skills_dir/disk-cleanup"
    echo "Linked skill: $skills_dir/disk-cleanup"
  fi
done

mkdir -p "$LOG_DIR" "$(dirname "$PLIST_PATH")"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_DIR/dev-disk-cleanup.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>86400</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/launchd-stdout.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/launchd-stderr.log</string>
</dict>
</plist>
EOF

GUI="gui/$(id -u)"
launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
launchctl bootstrap "$GUI" "$PLIST_PATH"

cat <<EOF

Installed. A first run has started; after that it runs daily and at login.
  Tier 1 (caches, stale agent builds) runs every time; tiers 2-3 only below
  THRESHOLD_GB free (default 50) or with --force.

  Preview:   $INSTALL_DIR/dev-disk-cleanup.sh --dry-run --force
  Settings:  $CONFIG_FILE
  Log:       $LOG_DIR/disk-cleanup.log
  Disable:   launchctl bootout $GUI/$LABEL
EOF
