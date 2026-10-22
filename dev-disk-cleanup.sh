#!/bin/bash
# dev-disk-cleanup: tiered disk cleanup for macOS developer machines.
# Cleans safe cache/build targets on a tiered basis.
#
# Usage:
#   ./dev-disk-cleanup.sh               # Tier 1 always; tiers 2-3 if below threshold
#   ./dev-disk-cleanup.sh --force       # Clean all tiers regardless of free space
#   ./dev-disk-cleanup.sh --dry-run     # Show what would be cleaned without deleting
#   ./dev-disk-cleanup.sh --backup-only # Run only ARCHIVE_HOOK's backup step
#
# Personal settings come from a sourced shell file (see config.example.sh):
#   $DEV_DISK_CLEANUP_CONFIG, else ~/.config/dev-disk-cleanup/config.sh

set -uo pipefail

# launchd does not inherit the interactive shell's package-manager/tool PATH.
export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# Defaults; any of these may be overridden by the config file.
LOG_DIR="$HOME/Library/Logs/dev-disk-cleanup"
THRESHOLD_GB=50
DERIVED_DATA_STALE_DAYS=14
DERIVED_DATA_PRIMARY_PROJECTS=()    # project folders you build in Xcode; other DerivedData counts as agent builds
CLEAN_DOWNLOADED_INSTALLERS=false   # delete ~/Downloads/*.dmg and *.xip in tier 2
EXTRA_CACHE_TARGETS=()              # "path|label" entries cleaned in tier 1
EXTRA_BUILD_TARGETS=()              # "path|label" entries cleaned in tier 2
ARCHIVE_HOOK=""                     # executable called as: backup | prune [--dry-run]

CONFIG_FILE="${DEV_DISK_CLEANUP_CONFIG:-$HOME/.config/dev-disk-cleanup/config.sh}"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  . "$CONFIG_FILE"
fi
LOG_FILE="$LOG_DIR/disk-cleanup.log"

FORCE=false
DRY_RUN=false
BACKUP_ONLY=false
CLEANUP_FAILED=false

for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=true ;;
    --dry-run) DRY_RUN=true ;;
    --backup-only) BACKUP_ONLY=true ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 64 ;;
  esac
done

mkdir -p "$LOG_DIR"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg"
  { echo "$msg" >> "$LOG_FILE"; } 2>/dev/null || true
}

get_free_kb() {
  df -k /System/Volumes/Data | awk 'NR==2 {print $4}'
}

format_kb_as_gib() {
  awk -v kb="$1" 'BEGIN {printf "%.1f", kb / 1024 / 1024}'
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
    rm -rf "$path" 2>/dev/null || true
    if [ -e "$path" ]; then
      local remaining_mb
      remaining_mb=$(dir_size_mb "$path")
      if [ "$remaining_mb" -le 5 ]; then
        # A running app recreates a few MB of its cache immediately.
        log "  Cleaned $label: ~$((size_mb - remaining_mb)) MB freed (${remaining_mb} MB in use)"
      else
        log "  PARTIAL cleanup for $label: ${size_mb} MB requested, ${remaining_mb} MB remains"
        CLEANUP_FAILED=true
      fi
    else
      log "  Cleaned $label: ${size_mb} MB freed"
    fi
  fi
}

clean_file() {
  local path="$1"
  local label="$2"
  [ -f "$path" ] || return
  local size_mb=$(( $(stat -f%z "$path" 2>/dev/null || echo 0) / 1048576 ))
  if $DRY_RUN; then
    log "  [DRY RUN] Would remove $label (${size_mb} MB): $path"
  else
    if rm -f "$path"; then
      log "  Removed $label: ${size_mb} MB freed"
    else
      log "  FAILED to remove $label: $path"
      CLEANUP_FAILED=true
    fi
  fi
}

clean_orphaned_ollama_blobs() {
  local blobs="$HOME/.ollama/blobs"
  local manifests="$HOME/.ollama/models/manifests"
  [ -d "$blobs" ] || return
  local referenced=false status
  # rg is available inside some agents but absent from launchd's PATH. Missing
  # tools/unreadable manifests must never be mistaken for unreferenced models.
  if [ ! -d "$manifests" ]; then
    log "  Skipping legacy Ollama blobs: cannot verify model manifests"
    return
  fi
  grep -r -F 'sha256:' "$manifests" >/dev/null 2>&1
  status=$?
  if [ "$status" -ne 0 ]; then
    log "  Skipping legacy Ollama blobs: no readable digest inventory"
    return
  fi
  if [ -d "$manifests" ]; then
    while IFS= read -r -d '' blob; do
      local digest="${blob##*/sha256-}"
      grep -r -F "$digest" "$manifests" >/dev/null 2>&1
      status=$?
      if [ "$status" -eq 0 ]; then
        referenced=true
        break
      elif [ "$status" -ne 1 ]; then
        log "  Skipping legacy Ollama blobs: manifest read failed"
        return
      fi
    done < <(find "$blobs" -maxdepth 1 -type f -print0)
  fi
  if $referenced; then
    log "  Skipping legacy Ollama blobs: a current manifest references them"
  else
    clean_target "$blobs" "unreferenced legacy Ollama blobs"
  fi
}

clean_stale_simulators() {
  local stale_days=30
  local devices_dir="$HOME/Library/Developer/CoreSimulator/Devices"
  [ -d "$devices_dir" ] || return
  local now cutoff
  now=$(date +%s)
  cutoff=$((now - stale_days * 86400))
  for device in "$devices_dir"/*; do
    [ -f "$device/device.plist" ] || continue
    local state last_booted boot_epoch device_id size_mb
    state=$(plutil -extract state raw -o - "$device/device.plist" 2>/dev/null || echo 0)
    last_booted=$(plutil -extract lastBootedAt raw -o - "$device/device.plist" 2>/dev/null || true)
    [ -n "$last_booted" ] || continue
    # plutil emits ISO-8601 timestamps (for example 2026-03-02T17:26:58Z).
    last_booted="${last_booted/T/ }"
    last_booted="${last_booted/Z/+0000}"
    boot_epoch=$(date -j -f '%Y-%m-%d %H:%M:%S %z' "$last_booted" +%s 2>/dev/null || echo "$now")
    [ "$state" = "3" ] && continue
    [ "$boot_epoch" -lt "$cutoff" ] || continue
    device_id=$(basename "$device")
    size_mb=$(dir_size_mb "$device")
    if $DRY_RUN; then
      log "  [DRY RUN] Would delete stale simulator $device_id (${size_mb} MB)"
    elif xcrun simctl delete "$device_id" 2>/dev/null; then
      log "  Deleted stale simulator $device_id: ${size_mb} MB freed"
    else
      log "  FAILED to delete stale simulator $device_id"
    fi
  done
}

# Config-supplied "path|label" entries; files and directories both work.
clean_configured_targets() {
  local entry path label
  for entry in "$@"; do
    path="${entry%%|*}"
    label="${entry#*|}"
    [ "$label" = "$entry" ] && label="$path"
    if [ -f "$path" ]; then
      clean_file "$path" "$label"
    else
      clean_target "$path" "$label"
    fi
  done
}

# Agent sessions build with `xcodebuild -derivedDataPath` into /tmp or their
# Claude scratchpad. Those copies (3-4 GiB each) bypass Xcode's DerivedData
# folder, so nothing else here ever removes them.
clean_stray_derived_data() {
  local tmp_root="${CLEANUP_TMP_ROOT:-/private/tmp}"
  local stale_hours=24
  $BELOW_THRESHOLD && stale_hours=12
  [ -d "$tmp_root" ] || return
  while IFS= read -r -d '' intermediates; do
    local dd
    dd=$(dirname "$(dirname "$intermediates")")
    [ -d "$dd" ] || continue
    if [ -n "$(find "$dd" -mmin -$((stale_hours * 60)) -print -quit 2>/dev/null)" ]; then
      log "  KEEPING agent build $dd (modified within ${stale_hours}h)"
      continue
    fi
    if pgrep -f -- "$dd" >/dev/null 2>&1; then
      log "  KEEPING agent build $dd (in use by a running process)"
      continue
    fi
    clean_target "$dd" "stale agent build"
  done < <(find "$tmp_root" -maxdepth 7 -type d -path '*/Build/Intermediates.noindex' -prune -print0 2>/dev/null)
}

# Xcode copies ~6 GiB of symbols for each iOS version a connected device has
# run, and recreates them on the next connect. Keep the newest per device model.
clean_superseded_device_support() {
  local ds="$HOME/Library/Developer/Xcode/iOS DeviceSupport"
  [ -d "$ds" ] || return
  local seen=" " cutoff entry model
  cutoff=$(( $(date +%s) - 30 * 86400 ))
  while IFS= read -r entry; do
    [ -d "$ds/$entry" ] || continue
    model="${entry%% *}"
    case "$seen" in
      *" $model "*)
        if [ "$(stat -f %m "$ds/$entry")" -lt "$cutoff" ]; then
          clean_target "$ds/$entry" "superseded iOS DeviceSupport ($entry)"
        fi ;;
      *) seen="$seen$model " ;;
    esac
  done < <(ls -t "$ds")
}

# Codex self-updates into packages/<name>/releases/<version>/ (~300 MB each)
# and never removes old versions. Keep the one `current` points at, the version
# before it (rollback) and any newer staged update; skip anything a running
# process still uses.
clean_superseded_codex_releases() {
  local pkg releases current version
  local -a older
  for pkg in "$HOME/.codex/packages"/*/; do
    pkg="${pkg%/}"
    releases="$pkg/releases"
    [ -d "$releases" ] || continue
    current=$(readlink "$pkg/current" 2>/dev/null) || current=""
    current="${current%/}"
    current="${current##*/}"
    if [ -z "$current" ] || [ ! -d "$releases/$current" ]; then
      log "  Skipping Codex releases in $pkg: cannot read the current version"
      continue
    fi
    older=()
    while IFS= read -r version; do
      [ "$version" = "$current" ] && break
      older+=("$version")
    done < <(ls "$releases" | sort -V)
    [ "${#older[@]}" -gt 1 ] || continue
    for version in "${older[@]:0:${#older[@]}-1}"; do
      if pgrep -f -- "$releases/$version/" >/dev/null 2>&1; then
        log "  KEEPING Codex release $version (in use by a running process)"
        continue
      fi
      clean_target "$releases/$version" "superseded Codex release ($(basename "$pkg") $version)"
    done
  done
}

# Rotate log if over 1 MB
if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  mv "$LOG_FILE" "$LOG_FILE.old"
fi

log "=========================================="
log "Disk cleanup started (force=$FORCE, dry_run=$DRY_RUN, backup_only=$BACKUP_ONLY)"

if $BACKUP_ONLY; then
  if [ -z "$ARCHIVE_HOOK" ]; then
    log "No ARCHIVE_HOOK configured; nothing to back up"
  elif $DRY_RUN; then
    log "[DRY RUN] Would run: $ARCHIVE_HOOK backup"
  else
    if ! "$ARCHIVE_HOOK" backup; then
      log "Backup-only run FAILED; chat sources retained"
      exit 1
    fi
  fi
  log "Backup-only run complete"
  exit 0
fi

FREE_BEFORE_KB=$(get_free_kb)
FREE_BEFORE=$(format_kb_as_gib "$FREE_BEFORE_KB")
log "Free space before: ${FREE_BEFORE} GiB"

BELOW_THRESHOLD=false
if [ "$FREE_BEFORE_KB" -lt $((THRESHOLD_GB * 1024 * 1024)) ]; then
  BELOW_THRESHOLD=true
  log "⚠️  Below ${THRESHOLD_GB} GiB threshold — running full cleanup"
fi

# ── Tier 1: Cache cleanup on each daily run ─────────────────────

log "── Tier 1: Cache cleanup ──"

clean_target "$HOME/Library/Caches/Adobe" "Adobe caches"

while IFS= read -r -d '' chrome_cache; do
  clean_target "$chrome_cache" "Chrome cache"
done < <(find "$HOME/Library/Caches/Google/Chrome" -maxdepth 2 -type d -name "Cache" -print0 2>/dev/null)

while IFS= read -r -d '' chrome_cache; do
  clean_target "$chrome_cache" "Chrome code cache"
done < <(find "$HOME/Library/Caches/Google/Chrome" -maxdepth 2 -type d -name "Code Cache" -print0 2>/dev/null)

clean_target "$HOME/Library/Caches/node-gyp" "node-gyp cache"
clean_target "$HOME/Library/Caches/ms-playwright" "Playwright cache"
clean_target "$HOME/Library/Caches/ms-playwright-go" "Playwright Go cache"
clean_target "$HOME/Library/Caches/org.whispersystems.signal-desktop.ShipIt" "Signal updater"
clean_target "$HOME/Library/Caches/Homebrew/downloads" "Homebrew downloads"
clean_target "$HOME/Library/Caches/org.swift.swiftpm/repositories" "SwiftPM repo cache"
clean_target "$HOME/Library/Caches/com.spotify.client" "Spotify cache"

# Chrome on-device AI model (redownloads if Chrome needs it)
clean_target "$HOME/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel" "Chrome on-device AI model"
clean_target "$HOME/Library/Application Support/Google/Chrome/Crashpad" "Chrome crash reports"

# Adobe & Creative Cloud logs
clean_target "$HOME/Library/Logs/Adobe" "Adobe logs"
clean_target "$HOME/Library/Logs/CreativeCloud" "Creative Cloud logs"
clean_target "$HOME/Library/Logs/NGL" "Adobe NGL logs"

# Cursor browser partition caches
for cursor_part_cache in "$HOME/Library/Application Support/Cursor/Partitions"/*/Cache; do
  [ -d "$cursor_part_cache" ] || continue
  clean_target "$cursor_part_cache" "Cursor partition cache ($(basename "$(dirname "$cursor_part_cache")"))"
done
for cursor_part_sw in "$HOME/Library/Application Support/Cursor/Partitions"/*/Service\ Worker; do
  [ -d "$cursor_part_sw" ] || continue
  clean_target "$cursor_part_sw" "Cursor partition Service Worker ($(basename "$(dirname "$cursor_part_sw")"))"
done

clean_target "$HOME/Library/Application Support/Cursor/CachedData" "Cursor CachedData"
clean_target "$HOME/Library/Application Support/Cursor/CachedExtensionVSIXs" "Cursor cached extension VSIXs"
clean_target "$HOME/Library/Application Support/Cursor/blob_storage" "Cursor blob storage"
clean_target "$HOME/Library/Application Support/Cursor/Cache" "Cursor cache"
clean_target "$HOME/Library/Application Support/Cursor/Code Cache" "Cursor code cache"
clean_target "$HOME/Library/Application Support/Cursor/GPUCache" "Cursor GPU cache"
clean_target "$HOME/Library/Application Support/Cursor/logs" "Cursor logs"

# Claude Desktop cache only. vm_bundles and local agent sessions are retained:
# they are runtime/session state, not a documented disposable cache.
clean_target "$HOME/Library/Application Support/Claude/Cache" "Claude cache"
clean_target "$HOME/Library/Application Support/Claude/Code Cache" "Claude code cache"
clean_target "$HOME/Library/Application Support/Claude/GPUCache" "Claude GPU cache"

# Codex keeps session and installed-package state. These two locations are safe
# scratch/cache data and do not include the active standalone installation.
clean_target "$HOME/.codex/cache" "Codex cache"
clean_target "$HOME/.codex/.tmp" "Codex temporary files"
clean_superseded_codex_releases

clean_target "$HOME/.cache/uv" "uv package cache"
clean_target "$HOME/Library/Caches/pip" "pip cache"
clean_target "$HOME/Library/Caches/com.apple.python" "Python bytecode cache"
clean_target "$HOME/.cache/puppeteer" "Puppeteer browser cache"
clean_target "$HOME/.cache/firebase" "Firebase cache"
clean_target "$HOME/Library/Application Support/Slack/Cache" "Slack cache"
clean_target "$HOME/Library/Application Support/Slack/Code Cache" "Slack code cache"
clean_target "$HOME/Library/Application Support/Slack/GPUCache" "Slack GPU cache"
clean_target "$HOME/Library/Application Support/Slack/logs" "Slack logs"

clean_stray_derived_data
clean_configured_targets ${EXTRA_CACHE_TARGETS[@]+"${EXTRA_CACHE_TARGETS[@]}"}

if ! $DRY_RUN; then
  npm_before=$(dir_size_mb "$HOME/.npm")
  if ! npm cache clean --force 2>/dev/null; then
    log "  npm cache cleanup failed"
    CLEANUP_FAILED=true
  fi
  npm_after=$(dir_size_mb "$HOME/.npm")
  npm_freed=$((npm_before - npm_after))
  if [ "$npm_freed" -gt 0 ]; then
    log "  Cleaned npm cache: ${npm_freed} MB freed"
  fi
fi

# ── Tier 2: Only when below threshold or --force ─────────────────

if $FORCE || $BELOW_THRESHOLD; then
  log "── Tier 2: Build artifacts cleanup ──"

  # Only unreferenced Ollama blobs; the active model store is preserved.
  clean_orphaned_ollama_blobs
  if $CLEAN_DOWNLOADED_INSTALLERS; then
    for installer in "$HOME/Downloads"/*.dmg "$HOME/Downloads"/*.xip; do
      [ -f "$installer" ] || continue
      clean_file "$installer" "downloaded installer"
    done
  fi
  clean_configured_targets ${EXTRA_BUILD_TARGETS[@]+"${EXTRA_BUILD_TARGETS[@]}"}

  STALE_DAYS=$DERIVED_DATA_STALE_DAYS
  log "  Keeping recent DerivedData per project; cleaning entries older than ${STALE_DAYS} days"

  # Agents that open a git worktree in Xcode get their own DerivedData folder
  # (3-10 GiB each) under the normal location. With DERIVED_DATA_PRIMARY_PROJECTS
  # set, builds of any other project fall under the agent-build idle window, as
  # do builds whose project no longer exists.
  agent_hours=24
  $BELOW_THRESHOLD && agent_hours=12

  for dd in "$HOME/Library/Developer/Xcode/DerivedData/"*/; do
    [ -d "$dd" ] || continue
    dd="${dd%/}"
    basename_dd=$(basename "$dd")
    case "$basename_dd" in
      ModuleCache.noindex|SymbolCache.noindex|SDKStatCaches.noindex|CompilationCache.noindex) continue ;;
    esac

    workspace=$(/usr/libexec/PlistBuddy -c "Print :WorkspacePath" "$dd/info.plist" 2>/dev/null || true)
    kind="stale"
    keep_secs=$((STALE_DAYS * 86400))
    keep_label="${STALE_DAYS} days"
    if [ -z "$workspace" ] || [ ! -e "$workspace" ]; then
      kind="project gone"
    elif [ ${#DERIVED_DATA_PRIMARY_PROJECTS[@]} -gt 0 ]; then
      kind="agent build"
      for project in "${DERIVED_DATA_PRIMARY_PROJECTS[@]}"; do
        [ "$(dirname "$workspace")" = "${project%/}" ] && kind="stale"
      done
    fi
    if [ "$kind" != "stale" ]; then
      keep_secs=$((agent_hours * 3600))
      keep_label="${agent_hours}h"
    fi

    # Check modification time — keep anything touched within the window
    last_modified=$(find "$dd" -maxdepth 1 -type d -print0 2>/dev/null | xargs -0 stat -f '%m' 2>/dev/null | sort -rn | head -1)
    now=$(date +%s)
    cutoff=$((now - keep_secs))

    if [ -n "$last_modified" ] && [ "$last_modified" -gt "$cutoff" ]; then
      size_mb=$(dir_size_mb "$dd")
      log "  KEEPING DerivedData/$basename_dd (${size_mb} MB) — modified within ${keep_label}"
    else
      clean_target "$dd" "DerivedData/$basename_dd ($kind)"
    fi
  done

  # Only clean Cursor's stale cache entries (files not accessed in 14+ days)
  for cursor_cache_dir in "$HOME/Library/Caches/Cursor/Cache_Data" "$HOME/Library/Caches/Cursor/Code Cache"; do
    [ -d "$cursor_cache_dir" ] || continue
    cache_label=$(basename "$cursor_cache_dir")
    stale_count=0
    stale_bytes=0
    while IFS= read -r -d '' f; do
      fsize=$(stat -f%z "$f" 2>/dev/null || echo 0)
      stale_bytes=$((stale_bytes + fsize))
      stale_count=$((stale_count + 1))
      if ! $DRY_RUN; then
        rm -f "$f"
      fi
    done < <(find "$cursor_cache_dir" -type f -atime +14 -print0 2>/dev/null)
    if [ "$stale_count" -gt 0 ]; then
      stale_mb=$((stale_bytes / 1048576))
      if $DRY_RUN; then
        log "  [DRY RUN] Would clean ${stale_count} stale files from Cursor $cache_label (~${stale_mb} MB)"
      else
        log "  Cleaned ${stale_count} stale files from Cursor $cache_label: ~${stale_mb} MB freed"
      fi
    fi
  done

  if ! $DRY_RUN; then
    log "  Removing unavailable iOS simulators..."
    xcrun simctl delete unavailable 2>/dev/null && log "  Cleaned unavailable simulators" || true
  else
    log "  [DRY RUN] Would remove unavailable iOS simulators"
  fi

  # Xcode ModuleCache (rebuilds on next compile)
  clean_target "$HOME/Library/Developer/Xcode/DerivedData/ModuleCache.noindex" "Xcode ModuleCache"
  clean_stale_simulators
  clean_superseded_device_support

  # Simulator runtimes are ~8 GiB each and re-download from Xcode Settings.
  if $DRY_RUN; then
    xcrun simctl runtime delete --notUsedSinceDays 60 --dry-run 2>&1 | while IFS= read -r line; do log "  [DRY RUN] runtime: $line"; done
  else
    xcrun simctl runtime delete --notUsedSinceDays 60 2>&1 | while IFS= read -r line; do log "  runtime: $line"; done
  fi

  # Chat retention belongs to ARCHIVE_HOOK, which must delete only what it has
  # verified in its archive. A hook failure marks the run partial.
  if [ -n "$ARCHIVE_HOOK" ]; then
    if $DRY_RUN; then
      "$ARCHIVE_HOOK" prune --dry-run || true
    elif ! "$ARCHIVE_HOOK" prune; then
      log "  ARCHIVE_HOOK prune FAILED; retaining unverified chat data"
      CLEANUP_FAILED=true
    fi
  fi
fi

# ── Tier 3: Archived data (iCloud-backed) ────────────────────────

if $FORCE || $BELOW_THRESHOLD; then
  log "── Tier 3: Archived data cleanup ──"
  
  # Transcript retention is handled only by ARCHIVE_HOOK after its per-file
  # verification. Directory mtime is not proof of a verified backup.
  # Cursor workspace images contain conversation context and are retained.
  log "  Keeping chat project folders and workspace images; transcript retention requires verified archives"

  # Claude downloads (can be re-downloaded if needed)
  CLAUDE_DOWNLOADS="$HOME/.claude/downloads"
  if [ -d "$CLAUDE_DOWNLOADS" ]; then
    downloads_size=$(dir_size_mb "$CLAUDE_DOWNLOADS")
    if [ "$downloads_size" -gt 50 ]; then
      # Clean files older than 14 days
      OLD_DOWNLOADS=$(find "$CLAUDE_DOWNLOADS" -type f -mtime +14 2>/dev/null)
      if [ -n "$OLD_DOWNLOADS" ]; then
        old_count=$(echo "$OLD_DOWNLOADS" | wc -l | tr -d ' ')
        old_bytes=0
        while IFS= read -r f; do
          fsize=$(stat -f%z "$f" 2>/dev/null || echo 0)
          old_bytes=$((old_bytes + fsize))
        done <<< "$OLD_DOWNLOADS"
        old_mb=$((old_bytes / 1048576))
        if [ "$old_mb" -gt 0 ]; then
          if $DRY_RUN; then
            log "  [DRY RUN] Would clean $old_count old Claude downloads (~${old_mb} MB)"
          else
            echo "$OLD_DOWNLOADS" | xargs rm -f
            log "  Cleaned $old_count old Claude downloads: ${old_mb} MB freed"
          fi
        fi
      fi
    fi
  fi
  
  # Claude project directories are live session data, not disposable cache.
  # Do not remove whole directories based on directory timestamps.

fi

FREE_AFTER_KB=$(get_free_kb)
FREE_AFTER=$(format_kb_as_gib "$FREE_AFTER_KB")
FREED_KB=$((FREE_AFTER_KB - FREE_BEFORE_KB))
FREED=$(format_kb_as_gib "$FREED_KB")

log "Free space after: ${FREE_AFTER} GiB (net change: ${FREED} GiB)"
if [ "$FREE_AFTER_KB" -lt $((THRESHOLD_GB * 1024 * 1024)) ]; then
  log "Still below ${THRESHOLD_GB} GiB: eligible cleanup cannot guarantee the threshold; recent builds and live data are retained"
fi
if $CLEANUP_FAILED; then
  log "Cleanup PARTIAL: one or more steps failed; see errors above"
  log "=========================================="
  exit 1
fi
log "Cleanup complete"
log "=========================================="
