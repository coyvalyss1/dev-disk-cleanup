#!/bin/bash
# dev-disk-cleanup - Smart disk space cleanup for macOS developers
# Safely cleans caches and build artifacts while preserving active work
#
# Usage:
#   ./dev-disk-cleanup.sh           # Normal: tier 1 weekly, tier 2 if below threshold
#   ./dev-disk-cleanup.sh --force   # Clean all tiers regardless of free space
#   ./dev-disk-cleanup.sh --dry-run # Show what would be cleaned without deleting

set -uo pipefail

# Configuration
SCRIPT_DIR="$HOME/.dev-disk-cleanup"
LOG_FILE="$SCRIPT_DIR/cleanup.log"
THRESHOLD_GB=50
STALE_DAYS=14
FORCE=false
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=true ;;
    --dry-run) DRY_RUN=true ;;
    --help)
      echo "dev-disk-cleanup - Smart disk space cleanup for macOS developers"
      echo ""
      echo "Usage:"
      echo "  ./dev-disk-cleanup.sh           # Normal cleanup (tier 1, or tier 2 if below ${THRESHOLD_GB} GB)"
      echo "  ./dev-disk-cleanup.sh --force   # Clean all tiers regardless of free space"
      echo "  ./dev-disk-cleanup.sh --dry-run # Show what would be cleaned without deleting"
      echo "  ./dev-disk-cleanup.sh --help    # Show this help"
      echo ""
      echo "Configuration:"
      echo "  Threshold: ${THRESHOLD_GB} GB (triggers tier 2 cleanup)"
      echo "  Stale period: ${STALE_DAYS} days (for build artifacts)"
      echo "  Logs: ${LOG_FILE}"
      exit 0
      ;;
  esac
done

mkdir -p "$SCRIPT_DIR"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg" | tee -a "$LOG_FILE"
}

get_free_gb() {
  df -g / | tail -1 | awk '{print $4}'
}

dir_size_mb() {
  if [ -d "$1" ]; then
    du -sm "$1" 2>/dev/null | awk '{print $1}'
  else
    echo "0"
  fi
}

clean_target() {
  local path="$1"
  local label="$2"

  if [ ! -e "$path" ]; then
    return
  fi

  local size_mb
  size_mb=$(dir_size_mb "$path")
  if [ "$size_mb" -eq 0 ]; then
    return
  fi

  if $DRY_RUN; then
    log "  [DRY RUN] Would clean $label (${size_mb} MB): $path"
  else
    rm -rf "$path"
    log "  Cleaned $label: ${size_mb} MB freed"
  fi
}

# Rotate log if over 1 MB
if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  mv "$LOG_FILE" "$LOG_FILE.old"
fi

log "=========================================="
log "dev-disk-cleanup started (force=$FORCE, dry_run=$DRY_RUN)"

FREE_BEFORE=$(get_free_gb)
log "Free space before: ${FREE_BEFORE} GB"

BELOW_THRESHOLD=false
if [ "$FREE_BEFORE" -lt "$THRESHOLD_GB" ]; then
  BELOW_THRESHOLD=true
  log "⚠️  Below ${THRESHOLD_GB} GB threshold — running full cleanup"
fi

# ── Tier 1: Always safe, run weekly ──────────────────────────────
# Browser caches, app updaters, package manager caches
# All regenerate automatically on next use

log "── Tier 1: Cache cleanup ──"

# Adobe caches (can grow to 50+ GB)
clean_target "$HOME/Library/Caches/Adobe" "Adobe caches"

# Chrome/Chromium browser caches (all profiles)
while IFS= read -r -d '' chrome_cache; do
  clean_target "$chrome_cache" "Chrome cache"
done < <(find "$HOME/Library/Caches/Google/Chrome" -maxdepth 2 -type d -name "Cache" -print0 2>/dev/null)

while IFS= read -r -d '' chrome_cache; do
  clean_target "$chrome_cache" "Chrome code cache"
done < <(find "$HOME/Library/Caches/Google/Chrome" -maxdepth 2 -type d -name "Code Cache" -print0 2>/dev/null)

# Development tool caches
clean_target "$HOME/Library/Caches/node-gyp" "node-gyp cache"
clean_target "$HOME/Library/Caches/ms-playwright" "Playwright cache"
clean_target "$HOME/Library/Caches/ms-playwright-go" "Playwright Go cache"
clean_target "$HOME/Library/Caches/Homebrew/downloads" "Homebrew downloads"
clean_target "$HOME/Library/Caches/org.swift.swiftpm/repositories" "SwiftPM repo cache"

# App updater caches
clean_target "$HOME/Library/Caches/org.whispersystems.signal-desktop.ShipIt" "Signal updater"
clean_target "$HOME/Library/Caches/ledger-live-desktop-updater" "Ledger updater"
clean_target "$HOME/Library/Caches/com.spotify.client" "Spotify cache"

# npm cache (uses npm's built-in clean command)
if ! $DRY_RUN && command -v npm &> /dev/null; then
  npm_before=$(dir_size_mb "$HOME/.npm")
  npm cache clean --force 2>/dev/null || true
  npm_after=$(dir_size_mb "$HOME/.npm")
  npm_freed=$((npm_before - npm_after))
  if [ "$npm_freed" -gt 0 ]; then
    log "  Cleaned npm cache: ${npm_freed} MB freed"
  fi
elif $DRY_RUN && command -v npm &> /dev/null; then
  npm_size=$(dir_size_mb "$HOME/.npm")
  if [ "$npm_size" -gt 0 ]; then
    log "  [DRY RUN] Would clean npm cache (~${npm_size} MB)"
  fi
fi

# ── Tier 2: Only when below threshold or --force ─────────────────
# Build artifacts that are safe to rebuild but take time to regenerate
# Preserves recent builds (modified within STALE_DAYS) for performance

if $FORCE || $BELOW_THRESHOLD; then
  log "── Tier 2: Build artifacts cleanup ──"

  # Xcode DerivedData — keeps recent builds, removes stale ones
  if [ -d "$HOME/Library/Developer/Xcode/DerivedData" ]; then
    log "  Keeping recent DerivedData per project; cleaning entries older than ${STALE_DAYS} days"

    for dd in "$HOME/Library/Developer/Xcode/DerivedData/"*/; do
      [ -d "$dd" ] || continue
      basename_dd=$(basename "$dd")
      case "$basename_dd" in
        ModuleCache.noindex|SymbolCache.noindex|SDKStatCaches.noindex|CompilationCache.noindex) continue ;;
      esac

      # Check modification time — keep anything touched in the last STALE_DAYS days
      last_modified=$(find "$dd" -maxdepth 1 -type d -print0 2>/dev/null | xargs -0 stat -f '%m' 2>/dev/null | sort -rn | head -1)
      now=$(date +%s)
      cutoff=$((now - STALE_DAYS * 86400))

      if [ -n "$last_modified" ] && [ "$last_modified" -gt "$cutoff" ]; then
        size_mb=$(dir_size_mb "$dd")
        log "  KEEPING DerivedData/$basename_dd (${size_mb} MB) — modified within ${STALE_DAYS} days"
      else
        clean_target "$dd" "DerivedData/$basename_dd (stale)"
      fi
    done
  fi

  # Cursor/VS Code editor caches — only removes stale cache files
  for cursor_cache_dir in "$HOME/Library/Caches/Cursor/Cache_Data" "$HOME/Library/Caches/Cursor/Code Cache" \
                          "$HOME/Library/Caches/com.microsoft.VSCode/Cache_Data" "$HOME/Library/Caches/com.microsoft.VSCode/Code Cache"; do
    [ -d "$cursor_cache_dir" ] || continue
    cache_label=$(basename "$cursor_cache_dir")
    editor_name=$(echo "$cursor_cache_dir" | grep -q "Cursor" && echo "Cursor" || echo "VS Code")
    stale_count=0
    stale_bytes=0
    while IFS= read -r -d '' f; do
      fsize=$(stat -f%z "$f" 2>/dev/null || echo 0)
      stale_bytes=$((stale_bytes + fsize))
      stale_count=$((stale_count + 1))
      if ! $DRY_RUN; then
        rm -f "$f"
      fi
    done < <(find "$cursor_cache_dir" -type f -atime +${STALE_DAYS} -print0 2>/dev/null)
    if [ "$stale_count" -gt 0 ]; then
      stale_mb=$((stale_bytes / 1048576))
      if $DRY_RUN; then
        log "  [DRY RUN] Would clean ${stale_count} stale files from $editor_name $cache_label (~${stale_mb} MB)"
      else
        log "  Cleaned ${stale_count} stale files from $editor_name $cache_label: ~${stale_mb} MB freed"
      fi
    fi
  done

  # iOS Simulators — only removes unavailable/broken ones
  if command -v xcrun &> /dev/null; then
    if ! $DRY_RUN; then
      log "  Removing unavailable iOS simulators..."
      xcrun simctl delete unavailable 2>/dev/null && log "  Cleaned unavailable simulators" || true
    else
      log "  [DRY RUN] Would remove unavailable iOS simulators"
    fi
  fi
fi

FREE_AFTER=$(get_free_gb)
FREED=$((FREE_AFTER - FREE_BEFORE))

log "Free space after: ${FREE_AFTER} GB (${FREED}+ GB recovered)"
log "Cleanup complete"
log "=========================================="

# Print summary to stdout if not piped to log
if [ -t 1 ]; then
  echo ""
  echo "✅ Cleanup complete: ${FREED} GB recovered"
  echo "📊 Free space: ${FREE_AFTER} GB"
  echo "📝 Full log: ${LOG_FILE}"
fi
