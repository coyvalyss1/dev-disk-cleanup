# Example dev-disk-cleanup settings. Copy to ~/.config/dev-disk-cleanup/config.sh
# (or point DEV_DISK_CLEANUP_CONFIG at your own file). Every setting is optional.

# Run tiers 2-3 when free space drops below this many GiB.
THRESHOLD_GB=50

# Keep Xcode DerivedData touched within this many days.
DERIVED_DATA_STALE_DAYS=14

# Delete ~/Downloads/*.dmg and *.xip during tier 2.
CLEAN_DOWNLOADED_INSTALLERS=false

# Extra "path|label" entries. Tier 1 runs every time; tier 2 only below threshold.
EXTRA_CACHE_TARGETS=(
  # "$HOME/Library/Caches/com.example.app|Example app cache"
)
EXTRA_BUILD_TARGETS=(
  # "$HOME/code/my-app/dist|my-app build output"
)

# Where the log goes.
# LOG_DIR="$HOME/Library/Logs/dev-disk-cleanup"

# Optional executable for AI chat retention, called as `backup` or `prune [--dry-run]`.
# It must delete only chats it has verified in its own archive; a nonzero exit
# marks the run partial.
# ARCHIVE_HOOK="$HOME/bin/my-chat-archive-hook.sh"
